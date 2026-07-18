// Builder: Direct Cranelift IR emission via eDSL FFI.
// Each FFI call creates a transient FunctionBuilder, emits one instruction,
// then drops it. SSA value lookups use safe .get() to avoid panics across FFI.

use cranelift_codegen::ir::types;
use cranelift_codegen::ir::condcodes::{IntCC, FloatCC};
use cranelift_codegen::ir::{AbiParam, Type, Signature, InstBuilder, MemFlagsData, UserFuncName, BlockArg};
use cranelift_codegen::isa::CallConv;
use cranelift_codegen::settings::Configurable;
use cranelift_codegen::Context;
use cranelift_frontend::{FunctionBuilder, FunctionBuilderContext};
use cranelift_module::{FuncId, Linkage, Module, DataId, DataDescription};
use cranelift_object::{ObjectBuilder, ObjectModule};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use target_lexicon::Triple;

// === Type enums (must match Julia's builder_emit.jl) ===
pub const TYPE_I32: u32 = 0;
pub const TYPE_I64: u32 = 1;
pub const TYPE_F32: u32 = 2;
pub const TYPE_F64: u32 = 3;
pub const TYPE_PTR: u32 = 4;
pub const TYPE_I8: u32 = 5;
pub const TYPE_I16: u32 = 6;

pub const ICMP_EQ: u32 = 0;  pub const ICMP_NE: u32 = 1;
pub const ICMP_SLT: u32 = 2; pub const ICMP_SGE: u32 = 3;
pub const ICMP_SGT: u32 = 4; pub const ICMP_SLE: u32 = 5;
pub const ICMP_ULT: u32 = 6; pub const ICMP_UGE: u32 = 7;
pub const ICMP_UGT: u32 = 8; pub const ICMP_ULE: u32 = 9;

pub const FCMP_EQ: u32 = 0; pub const FCMP_NE: u32 = 1;
pub const FCMP_LT: u32 = 2; pub const FCMP_LE: u32 = 3;
pub const FCMP_GT: u32 = 4; pub const FCMP_GE: u32 = 5;

// === Safely transmute Value(u32) and Block(u32) ===
use cranelift_codegen::ir::Value;
use cranelift_codegen::ir::Block;

#[inline] fn v2u(v: Value) -> u32 { unsafe { std::mem::transmute(v) } }

// === Per-function Cranelift building state ===

pub struct FunctionCtx {
    context: Context,
    fb_ctx: FunctionBuilderContext,
    // One persistent FunctionBuilder per function, behind a lifetime-erased raw
    // pointer. The old "transient FunctionBuilder per FFI call" pattern tripped
    // cranelift-frontend's `func_ctx.is_empty()` debug assertion: every dropped-
    // but-unfinalized builder leaves the context non-empty, so the *second*
    // FunctionBuilder::new panicked in debug builds (the assertion is gated on
    // debug_assertions, so release masked it). Now we create exactly one builder
    // (in init_entry, after this struct is boxed at a stable address) and reuse
    // it for every instruction; finalize_ctx frees it.
    //
    // Soundness: FunctionCtx owns `context` and `fb_ctx`; the builder borrows
    // `context.func` and `fb_ctx`; FunctionCtx is never moved after init_entry
    // (it is boxed once in add_function); no method touches `context` or
    // `fb_ctx` directly while the builder is alive (everything goes through fb());
    // and finalize_ctx drops the builder before define_function reads `context`.
    fb: *mut FunctionBuilder<'static>,
    ssa_values: HashMap<u32, Value>,
    blocks: HashMap<String, Block>,
    current_block: Block,
    signature: Signature,
    sealed: HashSet<Block>,
    func_name: String,  // original name for declare_function
}

#[inline]
fn block0() -> Block { unsafe { std::mem::transmute::<u32, Block>(0) } }

impl FunctionCtx {
    /// Phase 1 of two-phase init: build everything *except* the FunctionBuilder.
    /// Must be followed by `init_entry` once this FunctionCtx is at its final
    /// (boxed) address, because the builder borrows `context.func` and `fb_ctx`
    /// and would be invalidated by a move.
    pub fn new(name: &str, ret_type: u32, param_types: &[u32], call_conv: CallConv) -> Option<Self> {
        let mut sig = Signature::new(call_conv);
        if let Some(t) = map_type(ret_type) { sig.returns.push(AbiParam::new(t)); }
        for &pt in param_types {
            if let Some(t) = map_type(pt) { sig.params.push(AbiParam::new(t)); }
        }
        let mut context = Context::new();
        context.func.signature = sig.clone();
        context.func.name = UserFuncName::testcase(name);
        Some(FunctionCtx {
            context,
            fb_ctx: FunctionBuilderContext::new(),
            fb: std::ptr::null_mut(),
            ssa_values: HashMap::new(),
            blocks: HashMap::new(),
            current_block: block0(),  // real entry set in init_entry
            signature: sig,
            sealed: HashSet::new(),
            func_name: name.to_string(),
        })
    }

    /// Phase 2: create the single persistent FunctionBuilder plus the entry block
    /// and its params. Must run after the FunctionCtx is boxed (stable address).
    pub fn init_entry(&mut self) {
        // Create the builder from raw pointers to the borrowed fields, decoupling
        // from the borrow checker (self-referential borrow is the whole point).
        let func: *mut cranelift_codegen::ir::Function = &mut self.context.func;
        let fctx: *mut FunctionBuilderContext = &mut self.fb_ctx;
        let mut fb = unsafe { FunctionBuilder::new(&mut *func, &mut *fctx) };
        // `entry` holds the function params and immediately jumps to `block0`
        // (Julia IR block 1), so `block0` is NOT the Cranelift entry block.
        // Cranelift forbids branching TO the entry block; Julia block 1 is
        // frequently a while-loop condition with a back-edge to itself
        // (parse_chain, parse_generator, parse_decl_with_initial_ex), so it must
        // be a normal, branch-targetable block. Julia block 1 has no phi nodes,
        // so block0 takes no block params and the jump passes no args; the
        // function-param SSA values remain valid in block0 since entry dominates.
        let entry = fb.create_block();
        fb.switch_to_block(entry);
        fb.append_block_params_for_function_params(entry);
        let params: Vec<Value> = fb.func.dfg.block_params(entry).to_vec();
        let block0 = fb.create_block();
        fb.ins().jump(block0, &[]);
        fb.seal_block(entry);
        self.blocks.insert("block0".to_string(), block0);
        self.current_block = block0;
        self.fb = Box::into_raw(Box::new(fb)) as *mut FunctionBuilder<'static>;
        for (i, val) in params.iter().enumerate() {
            self.ssa_values.insert(i as u32, *val);
        }
    }

    /// Borrow the persistent builder. Callers must read any needed `self` fields
    /// (current_block, ssa values, blocks) into locals BEFORE this call, and scope
    /// the returned borrow so it ends before touching `self` again (the borrow is
    /// tied to `&mut self`).
    #[inline]
    fn fb(&mut self) -> &mut FunctionBuilder<'static> {
        debug_assert!(!self.fb.is_null(), "FunctionBuilder used after finalize_ctx");
        unsafe { &mut *self.fb }
    }

    fn ssa(&self, id: u32) -> Value {
        self.ssa_values.get(&id).copied().unwrap_or_else(|| { unsafe { std::mem::transmute::<u32, Value>(0) } })
    }

    /// Return the Cranelift type of SSA value `id` as our type enum.
    pub fn get_ssa_type(&mut self, id: u32) -> u32 {
        match self.ssa_values.get(&id) {
            Some(&v) => {
                let t = { let fb = self.fb(); fb.func.dfg.value_type(v) };
                map_type_rev(t)
            }
            None => 0xFF,  // unknown — caller should skip conversions
        }
    }

    fn emit<F: FnOnce(&mut FunctionBuilder) -> Value>(&mut self, f: F) -> u32 {
        let curr = self.current_block;
        let v = {
            let fb = self.fb();
            // Skip the redundant switch when already positioned on `curr`. The
            // persistent builder tracks fill-state, so re-switching to a Partial
            // block (instructions but no terminator yet) would trip the
            // "fill your block before switching" debug assertion.
            if fb.current_block() != Some(curr) { fb.switch_to_block(curr); }
            f(fb)
        };
        let id = v2u(v);
        self.ssa_values.insert(id, v);
        id
    }

    fn emit_void<F: FnOnce(&mut FunctionBuilder)>(&mut self, f: F) {
        let curr = self.current_block;
        let fb = self.fb();
        if fb.current_block() != Some(curr) { fb.switch_to_block(curr); }
        f(fb);
    }

    pub fn create_block_named(&mut self, name: &str) {
        let b = {
            let fb = self.fb();
            fb.create_block()
        };
        self.blocks.insert(name.to_string(), b);
    }

    pub fn switch_to_named(&mut self, name: &str) -> bool {
        self.blocks.get(name).map(|&b| { self.current_block = b; true }).unwrap_or(false)
    }

    pub fn seal_block(&mut self, name: &str) {
        let to_seal = self.blocks.get(name).copied().filter(|b| !self.sealed.contains(b));
        if let Some(b) = to_seal {
            { let fb = self.fb(); fb.seal_block(b); }
            self.sealed.insert(b);
        }
    }

    pub fn is_block_sealed(&self) -> bool { self.sealed.contains(&self.current_block) }

    // --- Constants ---
    pub fn emit_iconst(&mut self, val: i64, ty: u32) -> u32 {
        let t = map_type(ty).unwrap_or(types::I64);
        self.emit(|fb| fb.ins().iconst(t, val))
    }
    pub fn emit_f64const(&mut self, val: f64) -> u32 { self.emit(|fb| fb.ins().f64const(val)) }
    pub fn emit_f32const(&mut self, val: f32) -> u32 { self.emit(|fb| fb.ins().f32const(val)) }

    // --- Arithmetic ---
    pub fn emit_iadd(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().iadd(lv, rv)) }
    pub fn emit_isub(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().isub(lv, rv)) }
    pub fn emit_imul(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().imul(lv, rv)) }
    pub fn emit_sdiv(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().sdiv(lv, rv)) }
    pub fn emit_udiv(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().udiv(lv, rv)) }
    pub fn emit_srem(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().srem(lv, rv)) }
    pub fn emit_urem(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().urem(lv, rv)) }

    // --- Comparisons ---
    pub fn emit_icmp(&mut self, cond: IntCC, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().icmp(cond, lv, rv)) }
    pub fn emit_fcmp(&mut self, cond: FloatCC, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().fcmp(cond, lv, rv)) }
    // select(cond, then, else): returns `then` when cond (a b1 from icmp) is true.
    pub fn emit_select(&mut self, cond: u32, t: u32, e: u32) -> u32 { let (cv, tv, ev) = (self.ssa(cond), self.ssa(t), self.ssa(e)); self.emit(|fb| fb.ins().select(cv, tv, ev)) }

    // --- Bitwise ---
    pub fn emit_band(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().band(lv, rv)) }
    pub fn emit_bor(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().bor(lv, rv)) }
    pub fn emit_bxor(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().bxor(lv, rv)) }
    pub fn emit_ishl(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().ishl(lv, rv)) }
    pub fn emit_ushr(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().ushr(lv, rv)) }
    pub fn emit_sshr(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = self.harmonize_binop(l, r); self.emit(|fb| fb.ins().sshr(lv, rv)) }
    // bit-count / byte-swap unops (Cranelift infers operand/result type; same width in/out)
    pub fn emit_clz(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().clz(vv)) }
    pub fn emit_ctz(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().ctz(vv)) }
    pub fn emit_popcnt(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().popcnt(vv)) }
    pub fn emit_bswap(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().bswap(vv)) }

    // --- Conversions ---
    pub fn emit_uextend(&mut self, v: u32, tt: u32) -> u32 {
        let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::I64);
        let st = self.ssa_type(vv);
        if st == t || (st == types::I64 && t == types::I32) { return v; }  // no-op or can't extend
        self.emit(|fb| fb.ins().uextend(t, vv))
    }
    pub fn emit_sextend(&mut self, v: u32, tt: u32) -> u32 {
        let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::I64);
        let st = self.ssa_type(vv);
        if st == t || (st == types::I64 && t == types::I32) { return v; }  // no-op or can't extend
        self.emit(|fb| fb.ins().sextend(t, vv))
    }
    pub fn emit_ireduce(&mut self, v: u32, tt: u32) -> u32 {
        let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::I32);
        if self.ssa_type(vv) == t { return v; }  // no-op
        self.emit(|fb| fb.ins().ireduce(t, vv))
    }
    fn harmonize_binop(&mut self, l: u32, r: u32) -> (Value, Value) {
        let (lv, rv) = (self.ssa(l), self.ssa(r));
        let fb = self.fb();
        let lt = fb.func.dfg.value_type(lv);
        let rt = fb.func.dfg.value_type(rv);
        // Always extend narrow to wide — never reduce.
        let lv2 = if lt == types::I32 && rt == types::I64 { fb.ins().uextend(types::I64, lv) } else { lv };
        let rv2 = if rt == types::I32 && lt == types::I64 { fb.ins().uextend(types::I64, rv) } else { rv };
        (lv2, rv2)
    }
    fn ssa_type(&mut self, v: Value) -> Type {
        let fb = self.fb();
        fb.func.dfg.value_type(v)
    }
    // int -> float (result float type tt)
    pub fn emit_fcvt_from_sint(&mut self, v: u32, tt: u32) -> u32 { let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::F64); self.emit(|fb| fb.ins().fcvt_from_sint(t, vv)) }
    pub fn emit_fcvt_from_uint(&mut self, v: u32, tt: u32) -> u32 { let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::F64); self.emit(|fb| fb.ins().fcvt_from_uint(t, vv)) }
    // float -> int (saturating; result int type tt). Saturating matches Julia's
    // unsafe_trunc latitude (NaN->0, out-of-range saturate); the trapping variants
    // would crash on NaN/overflow.
    pub fn emit_fcvt_to_sint_sat(&mut self, v: u32, tt: u32) -> u32 { let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::I64); self.emit(|fb| fb.ins().fcvt_to_sint_sat(t, vv)) }
    pub fn emit_fcvt_to_uint_sat(&mut self, v: u32, tt: u32) -> u32 { let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::I64); self.emit(|fb| fb.ins().fcvt_to_uint_sat(t, vv)) }
    // float width changes (typed — result type tt: F32 for fdemote, F64 for fpromote)
    pub fn emit_fdemote(&mut self, v: u32, tt: u32) -> u32 { let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::F32); self.emit(|fb| fb.ins().fdemote(t, vv)) }
    pub fn emit_fpromote(&mut self, v: u32, tt: u32) -> u32 { let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::F64); self.emit(|fb| fb.ins().fpromote(t, vv)) }

    // --- Float ---
    pub fn emit_fadd(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().fadd(lv, rv)) }
    pub fn emit_fsub(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().fsub(lv, rv)) }
    pub fn emit_fmul(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().fmul(lv, rv)) }
    pub fn emit_fdiv(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().fdiv(lv, rv)) }
    pub fn emit_fneg(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().fneg(vv)) }
    // float math unops (Cranelift infers operand/result type)
    pub fn emit_sqrt(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().sqrt(vv)) }
    pub fn emit_fceil(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().ceil(vv)) }
    pub fn emit_ffloor(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().floor(vv)) }
    pub fn emit_ftrunc(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().trunc(vv)) }
    pub fn emit_fnearest(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().nearest(vv)) }
    pub fn emit_fabs(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().fabs(vv)) }
    pub fn emit_fcopysign(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().fcopysign(lv, rv)) }

    // --- Memory ---
    pub fn emit_load(&mut self, ptr: u32, offset: i32, ty: u32) -> u32 {
        let pv = self.ssa(ptr); let t = map_type(ty).unwrap_or(types::I64);
        self.emit(|fb| fb.ins().load(t, MemFlagsData::new(), pv, offset))
    }
    pub fn emit_store(&mut self, ptr: u32, offset: i32, value: u32, _ty: u32) {
        let (pv, vv) = (self.ssa(ptr), self.ssa(value));
        self.emit_void(|fb| { fb.ins().store(MemFlagsData::new(), vv, pv, offset); });
    }


    // --- Control flow ---
    pub fn append_block_param(&mut self, block_name: &str, ty: u32) -> u32 {
        let t = map_type(ty).unwrap_or(types::I64);
        let b = *self.blocks.get(block_name).unwrap_or(&self.current_block);
        let v = {
            let fb = self.fb();
            fb.append_block_param(b, t)
        };
        let id = v2u(v);
        self.ssa_values.insert(id, v);
        id
    }

    pub fn emit_jump_with_args(&mut self, target: &str, args: &[u32]) {
        let saved_curr = self.current_block;
        // If the target block doesn't exist, create it with a trap terminator.
        if !self.blocks.contains_key(target) {
            let fb = self.fb();
            let b = fb.create_block();
            fb.switch_to_block(b);
            fb.ins().trap(cranelift_codegen::ir::TrapCode::HEAP_OUT_OF_BOUNDS);
            fb.seal_block(b);
            self.blocks.insert(target.to_string(), b);
        }
        self.current_block = saved_curr;
        let t = *self.blocks.get(target).unwrap_or(&self.current_block);
        let curr = self.current_block;
        let arg_vals: Vec<Value> = args.iter().map(|&a| self.ssa(a)).collect();
        {
            let fb = self.fb();
            if fb.current_block() != Some(curr) { fb.switch_to_block(curr); }
            let params = fb.func.dfg.block_params(t);
            let param_types: Vec<types::Type> = params.iter().map(|&p| fb.func.dfg.value_type(p)).collect();
            let arg_vals2: Vec<BlockArg> = arg_vals.iter().enumerate().map(|(i, &v)| {
                if i < param_types.len() {
                    let vt = fb.func.dfg.value_type(v);
                    let expected = param_types[i];
                    let v = if vt == types::I32 && expected == types::I64 {
                        fb.ins().uextend(types::I64, v)
                    } else if vt == types::I64 && expected == types::I32 {
                        fb.ins().ireduce(types::I32, v)
                    } else { v };
                    return v.into();
                }
                v.into()
            }).collect();
            fb.ins().jump(t, arg_vals2.iter());
        };
        self.sealed.insert(curr);
    }

    pub fn emit_jump(&mut self, target: &str) {
        self.emit_jump_with_args(target, &[]);
    }

    pub fn emit_brif_with_args(&mut self, cond: u32, then_s: &str, then_args: &[u32], else_s: &str, else_args: &[u32]) {
        let saved = self.current_block;
        // Auto-create missing target blocks
        for &target in &[then_s, else_s] {
            if !self.blocks.contains_key(target) {
                let fb = self.fb();
                let b = fb.create_block();
                fb.switch_to_block(b);
                fb.ins().trap(cranelift_codegen::ir::TrapCode::HEAP_OUT_OF_BOUNDS);
                fb.seal_block(b);
                self.blocks.insert(target.to_string(), b);
            }
        }
        self.current_block = saved;
        let cv = self.ssa(cond);
        let curr = self.current_block;
        let t = *self.blocks.get(then_s).unwrap_or(&self.current_block);
        let e = *self.blocks.get(else_s).unwrap_or(&self.current_block);
        let t_vals: Vec<Value> = then_args.iter().map(|&a| self.ssa(a)).collect();
        let e_vals: Vec<Value> = else_args.iter().map(|&a| self.ssa(a)).collect();
        {
            let fb = self.fb();
            if fb.current_block() != Some(curr) { fb.switch_to_block(curr); }
            let t_params = fb.func.dfg.block_params(t);
            let t_types: Vec<types::Type> = t_params.iter().map(|&p| fb.func.dfg.value_type(p)).collect();
            let e_params = fb.func.dfg.block_params(e);
            let e_types: Vec<types::Type> = e_params.iter().map(|&p| fb.func.dfg.value_type(p)).collect();
            let mut harmonize = |vals: &[Value], types: &[types::Type]| -> Vec<BlockArg> {
                vals.iter().enumerate().map(|(i, &v)| {
                    if i < types.len() {
                        let vt = fb.func.dfg.value_type(v);
                        let expected = types[i];
                        let v = if vt == types::I32 && expected == types::I64 {
                            fb.ins().uextend(types::I64, v)
                        } else if vt == types::I64 && expected == types::I32 {
                            fb.ins().ireduce(types::I32, v)
                        } else { v };
                        return v.into();
                    }
                    v.into()
                }).collect()
            };
            let t_args: Vec<BlockArg> = harmonize(&t_vals, &t_types);
            let e_args: Vec<BlockArg> = harmonize(&e_vals, &e_types);
            let cvi8 = if fb.func.dfg.value_type(cv) == types::I8 {
                cv
            } else {
                fb.ins().ireduce(types::I8, cv)
            };
            fb.ins().brif(cvi8, t, t_args.iter(), e, e_args.iter());
        }
        self.sealed.insert(curr);
    }

    pub fn emit_brif(&mut self, cond: u32, then_s: &str, else_s: &str) {
        self.emit_brif_with_args(cond, then_s, &[], else_s, &[]);
    }
    pub fn emit_return(&mut self, val: u32) {
        let v = self.ssa(val); let curr = self.current_block;
        self.emit_void(|fb| {
            let vt = fb.func.dfg.value_type(v);
            let expected = fb.func.signature.returns[0].value_type;
            let v2 = if vt == types::I64 && expected == types::I32 { fb.ins().ireduce(types::I32, v) }
                else if vt == types::I32 && expected == types::I64 { fb.ins().uextend(types::I64, v) }
                else { v };
            fb.ins().return_(&[v2]);
        });
        self.sealed.insert(curr);
    }
    pub fn emit_return_void(&mut self) { let curr = self.current_block; self.emit_void(|fb| { fb.ins().return_(&[]); }); self.sealed.insert(curr); }
    pub fn emit_trap(&mut self) { let curr = self.current_block; self.emit_void(|fb| { fb.ins().trap(cranelift_codegen::ir::TrapCode::HEAP_OUT_OF_BOUNDS); }); self.sealed.insert(curr); }
    /// Conditional trap: traps with HEAP_OUT_OF_BOUNDS if `v` is nonzero. Used for
    /// bounds checks matching Wasm's array.get OOB-trap semantics. NOT a terminator
    /// — execution continues to the next instruction if v==0.
    pub fn emit_trapnz(&mut self, v: u32) {
        let vv = self.ssa(v);
        self.emit_void(|fb| { fb.ins().trapnz(vv, cranelift_codegen::ir::TrapCode::HEAP_OUT_OF_BOUNDS); });
    }
    /// Memory fence: prevents Cranelift's egraph from hoisting mutable-struct
    /// field loads across self-recursive :invoke calls which may have mutated
    /// those fields through the passed-by-pointer argument (fixes the
    /// `parse_RtoL` lookahead_index-hoisting bug).
    pub fn emit_fence(&mut self) {
        self.emit_void(|fb| { fb.ins().fence(); });
    }

    pub fn emit_call_import(&mut self, module: &mut ObjectModule, imports: &HashMap<String, FuncId>, name: &str, arg_ids: &[u32]) -> u32 {
        let func_id = *imports.get(name).unwrap_or_else(|| panic!("import not declared: {}", name));
        let arg_vals: Vec<Value> = arg_ids.iter().map(|&id| self.ssa(id)).collect();
        let curr = self.current_block;
        let result = {
            let fb = self.fb();
            if fb.current_block() != Some(curr) { fb.switch_to_block(curr); }
            let func_ref = module.declare_func_in_func(func_id, &mut fb.func);
            let param_types: Vec<types::Type> = {
                let sig_ref = fb.func.dfg.ext_funcs[func_ref].signature;
                fb.func.dfg.signatures[sig_ref].params.iter().map(|p| p.value_type).collect()
            };
            let args: Vec<Value> = (0..param_types.len()).map(|i| {
                if i < arg_vals.len() {
                    let v = arg_vals[i];
                    let vt = fb.func.dfg.value_type(v);
                    let expected = param_types[i];
                    if vt == types::I32 && expected == types::I64 {
                        fb.ins().uextend(types::I64, v)
                    } else if vt == types::I64 && expected == types::I32 {
                        fb.ins().ireduce(types::I32, v)
                    } else { v }
                } else {
                    // Pad missing args with 0
                    let expected = param_types[i];
                    if expected == types::I64 { fb.ins().iconst(types::I64, 0) }
                    else { fb.ins().iconst(types::I32, 0) }
                }
            }).collect();
            let call = fb.ins().call(func_ref, &args);
            let results = fb.inst_results(call);
            if results.is_empty() { return 0; }  // void-returning import
            results[0]
        };
        let id = v2u(result);
        self.ssa_values.insert(id, result);
        id
    }

    /// Materialize the runtime address of a declared data symbol (a byte blob
    /// in the .so's .rodata/.data) as an i64 value. PC-relative/GOT relocation
    /// resolved at load — NOT a baked host pointer. Used so string literals and
    /// const tables live in the .so itself. Like iconst, the value is block-scoped
    /// (Cranelift SSA dominance): emit fresh per block.
    pub fn emit_symbol_value(
        &mut self, module: &mut ObjectModule,
        data: &HashMap<String, DataId>, name: &str,
    ) -> u32 {
        let data_id = *data.get(name).unwrap_or_else(|| panic!("data not declared: {}", name));
        let curr = self.current_block;
        let result = {
            let fb = self.fb();
            if fb.current_block() != Some(curr) { fb.switch_to_block(curr); }
            let gv = module.declare_data_in_func(data_id, &mut fb.func);
            fb.ins().symbol_value(types::I64, gv)
        };
        let id = v2u(result);
        self.ssa_values.insert(id, result);
        id
    }

    pub fn finalize_ctx(&mut self) -> Result<(), String> {
        // Guarantee a valid entry block. A block only enters the layout when an
        // instruction is emitted into it (frontend's ensure_inserted_block →
        // layout.append_block); create_block/switch_to_block/append_block_param do
        // not. If body emission threw before any instruction landed in a block
        // (e.g. a rethrown non-CompileError emitter bug on the entry block's first
        // statement), the layout is empty: layout.entry_block() == None.
        // remove_constant_phis runs UNCONDITIONALLY during compilation
        // (Context::optimize calls it at every opt_level, including "none" — only
        // the egraph pass is opt-gated) and does
        // func.layout.entry_block().expect("...entry block unknown"), aborting the
        // whole process with an un-catchable panic. Emit a trap into the
        // already-created entry block so it is inserted into the layout; such a
        // callee then traps at runtime, the correct outcome for a body that could
        // not be lowered.
        if self.context.func.layout.entry_block().is_none() {
            let entry = *self.blocks.get("block0")
                .expect("entry block0 must exist (init_entry creates it)");
            {
                let fb = self.fb();
                if fb.current_block() != Some(entry) { fb.switch_to_block(entry); }
                fb.ins().trap(cranelift_codegen::ir::TrapCode::HEAP_OUT_OF_BOUNDS);
            }
        }

        // Seal any blocks not explicitly sealed (e.g. implicit-jump fallthrough).
        let unsealed: Vec<Block> = self.blocks.values().copied()
            .filter(|b| !self.sealed.contains(b)).collect();
        {
            let fb = self.fb();
            for b in &unsealed { fb.seal_block(*b); }
        }
        // Free the persistent builder. FunctionBuilder has no Drop impl and we
        // intentionally do NOT call its `finalize(mut self)` here (its seal/fill/
        // basic-block debug checks would need the context intact, and its safepoint
        // pass is unused). The Function in self.context is complete; module.define_function
        // runs Cranelift's verifier during compilation. fb_ctx is left non-empty and
        // dropped with FunctionCtx — no further builders are created.
        if !self.fb.is_null() {
            unsafe { drop(Box::from_raw(self.fb)); }
            self.fb = std::ptr::null_mut();
        }
        Ok(())
    }
}

// === BuilderContext ===

pub struct BuilderContext {
    module: Option<ObjectModule>,
    pub(crate) funcs: Vec<Box<FunctionCtx>>,
    pub(crate) imports: HashMap<String, FuncId>,
    pub(crate) self_imports: HashMap<String, FuncId>,
    pub(crate) data: HashMap<String, DataId>,
    call_conv: CallConv,
    done: bool,
}

impl BuilderContext {
    pub fn new() -> Self {
        let triple = Triple::host();
        let mut fb = cranelift_codegen::settings::builder();
        fb.set("is_pic", "true").unwrap();
        // opt_level "speed" enables the egraph pass. remove_constant_phis runs
        // unconditionally at every opt_level (Context::optimize), so the prior
        // "none" did NOT skip it — the entry_block panic it claimed to dodge is
        // prevented in finalize_ctx, which guarantees a valid entry block for
        // every function. Keep optimizations on; assert correctness via tests.
        fb.set("opt_level", "speed").unwrap();
        let flags = cranelift_codegen::settings::Flags::new(fb);
        let isa = cranelift_codegen::isa::lookup(triple)
            .expect("ISA lookup").finish(flags).expect("ISA finish");
        let call_conv = isa.default_call_conv();
        let lcn = Box::new(cranelift_module::default_libcall_names());
        let ob = ObjectBuilder::new(isa, "obj", lcn).expect("ObjBuilder");
        let module = ObjectModule::new(ob);
        BuilderContext { module: Some(module), funcs: Vec::new(), imports: HashMap::new(), self_imports: HashMap::new(), data: HashMap::new(), call_conv, done: false }
    }

    pub fn add_function(&mut self, n: &str, rt: u32, pts: &[u32]) -> Option<*mut FunctionCtx> {
        let fc = FunctionCtx::new(n, rt, pts, self.call_conv)?;
        let mut bx = Box::new(fc);
        // Phase 2 init: create the persistent FunctionBuilder now that the
        // FunctionCtx is at its final (boxed) address.
        bx.init_entry();
        let p: *mut FunctionCtx = &mut *bx; self.funcs.push(bx); Some(p)
    }

    pub fn module_mut(&mut self) -> &mut ObjectModule { self.module.as_mut().expect("module already taken") }

    pub fn declare_import(&mut self, name: &str, ret_type: u32, param_types: &[u32]) -> Result<(), String> {
        let mut sig = Signature::new(self.call_conv);
        if let Some(t) = map_type(ret_type) { sig.returns.push(AbiParam::new(t)); }
        for &pt in param_types {
            if let Some(t) = map_type(pt) { sig.params.push(AbiParam::new(t)); }
        }
        let fid = self.module.as_mut().unwrap().declare_function(name, Linkage::Import, &sig)
            .map_err(|e| format!("declare import {}: {}", name, e))?;
        self.imports.insert(name.to_string(), fid);
        Ok(())
    }

    /// Pre-declare the function being compiled as callable BEFORE its body is emitted,
    /// enabling recursive self-calls. Uses Linkage::Export so it can be called from
    /// within the module AND from external callers. The FuncId is stored in
    /// self_imports and reused in finalize() to avoid duplicate declaration.
    pub fn declare_self_function(&mut self, name: &str, ret_type: u32, param_types: &[u32]) -> Result<(), String> {
        let mut sig = Signature::new(self.call_conv);
        if let Some(t) = map_type(ret_type) { sig.returns.push(AbiParam::new(t)); }
        for &pt in param_types {
            if let Some(t) = map_type(pt) { sig.params.push(AbiParam::new(t)); }
        }
        let fid = self.module.as_mut().unwrap()
            .declare_function(name, Linkage::Export, &sig)
            .map_err(|e| format!("declare self-function {}: {}", name, e))?;
        self.imports.insert(name.to_string(), fid);
        self.self_imports.insert(name.to_string(), fid);
        Ok(())
    }

    /// Declare a data object (a byte blob living in the final .so's .rodata or
    /// .data). Used to carry string-literal bytes and const tables so the .so no
    /// longer bakes Julia-heap pointers to them. `writable=false` → .rodata
    /// (read-only); `true` → .data (for lazy type-tag fixup). Local linkage: the
    /// blob is only referenced within this module (via symbol_value).
    pub fn declare_data(&mut self, name: &str, writable: bool) -> Result<(), String> {
        if self.data.contains_key(name) { return Ok(()); }
        let did = self.module.as_mut().unwrap()
            .declare_data(name, Linkage::Local, writable, false)
            .map_err(|e| format!("declare data {}: {}", name, e))?;
        self.data.insert(name.to_string(), did);
        Ok(())
    }

    /// Define a previously-declared data object's contents. Must be called before
    /// finalize() (which calls module.finish()). Idempotent redefinition is an
    /// error in Cranelift — callers declare+define once per name.
    pub fn define_data(&mut self, name: &str, bytes: &[u8]) -> Result<(), String> {
        let did = *self.data.get(name)
            .ok_or_else(|| format!("define data {}: not declared", name))?;
        let mut dd = DataDescription::new();
        dd.define(bytes.into());
        self.module.as_mut().unwrap().define_data(did, &dd)
            .map_err(|e| format!("define data {}: {}", name, e))?;
        Ok(())
    }

    pub fn finalize(&mut self, path: &Path) -> Result<(), String> {
        if self.done { return Err("already finalized".into()); }
        // Per-function progress logs are noisy (one declare+defined pair per fn,
        // printed for every compiled function across the whole test suite). Gate
        // them behind NATIVE_BUILDER_VERBOSE so the default run is quiet.
        let verbose = std::env::var("NATIVE_BUILDER_VERBOSE").is_ok();
        let mut module = self.module.take().ok_or("module already taken")?;
        for f in self.funcs.iter_mut() {
            f.finalize_ctx()?;
            let nm = f.func_name.clone();
            let sig = f.signature.clone();
            if verbose { eprintln!("[native-builder] declaring: {}", nm); }
            // Diagnostic dump: if NATIVE_BUILDER_DUMP_DIR is set, write each
            // function's Cranelift IR (Display) to <dir>/<escaped-name>.cranelift.
            // Captures failing functions too (dumped before define_function).
            if let Ok(dir) = std::env::var("NATIVE_BUILDER_DUMP_DIR") {
                let escaped: String = nm.chars().map(|c| match c {
                    'A'..='Z'|'a'..='z'|'0'..='9'|'_' => c,
                    _ => '_',
                }).collect();
                let p = std::path::Path::new(&dir).join(format!("{}.cranelift", escaped));
                let _ = std::fs::write(p, format!("{}", f.context.func.display()));
            }
            // Reuse pre-declared FuncId (from declare_self_function) to avoid
            // duplicate Linkage::Export declaration for recursive functions.
            let fid = if let Some(&fid) = self.self_imports.get(&nm) {
                fid
            } else {
                module.declare_function(&nm, Linkage::Export, &sig)
                    .map_err(|e| format!("declare {}: {}", nm, e))?
            };
            match module.define_function(fid, &mut f.context) {
                Ok(()) => { if verbose { eprintln!("[native-builder] defined: {}", nm); } }
                Err(e) => {
                    // Verification failed on the emitted body (e.g. an invalid
                    // block reference from an unsupported lowering). The function
                    // was pre-declared Linkage::Export (for recursive self-calls),
                    // and ObjectModule::finish() PANICS — does not return Err — on
                    // an undefined Export symbol, which would abort the whole
                    // process (un-catchable from Julia). Define a minimal trap
                    // stub so the symbol is satisfied, the module links, and the
                    // callee traps at runtime (correct for a body that could not be
                    // lowered). The stub's entry block receives the trap, so it is
                    // in the layout and remove_constant_phis stays safe.
                    eprintln!("[native-builder] warning: {} verification failed ({:?}); defining trap stub", nm, e);
                    define_trap_stub(&mut module, fid, &sig)?;
                }
            }
        }
        let obj = module.finish().emit().map_err(|e| format!("emit: {}", e))?;
        std::fs::write(path, &obj).map_err(|e| format!("write: {}", e))?;
        self.done = true; Ok(())
    }
}

/// Define already-declared `fid` with a minimal body that traps immediately.
/// Used when a function's real body failed verification: it was pre-declared
/// `Linkage::Export` (for recursive self-calls), and `ObjectModule::finish()`
/// panics — does not return `Err` — on an undefined Export symbol. The stub
/// satisfies the symbol so the module links, and the callee traps at runtime
/// (correct for a body that could not be lowered). The entry block receives the
/// trap instruction, so it is inserted into the layout and `remove_constant_phis`
/// (which requires a valid entry block) stays safe.
fn define_trap_stub(module: &mut ObjectModule, fid: FuncId, sig: &Signature) -> Result<(), String> {
    let mut ctx = Context::for_function(cranelift_codegen::ir::Function::with_name_signature(
        UserFuncName::testcase("trap_stub"), sig.clone()));
    {
        let mut fb_ctx = FunctionBuilderContext::new();
        let mut fb = FunctionBuilder::new(&mut ctx.func, &mut fb_ctx);
        let entry = fb.create_block();
        fb.switch_to_block(entry);
        fb.append_block_params_for_function_params(entry);
        fb.ins().trap(cranelift_codegen::ir::TrapCode::HEAP_OUT_OF_BOUNDS);
        fb.seal_all_blocks();
        fb.finalize();
    }
    module.define_function(fid, &mut ctx).map(|_| ()).map_err(|e| format!("{:?}", e))
}

// === Helpers ===

pub fn map_type(t: u32) -> Option<Type> {
    match t { TYPE_I32=>Some(types::I32), TYPE_I64=>Some(types::I64), TYPE_F32=>Some(types::F32), TYPE_F64=>Some(types::F64), TYPE_PTR=>Some(types::I64), TYPE_I8=>Some(types::I8), TYPE_I16=>Some(types::I16), _=>None }
}
pub fn map_type_rev(t: Type) -> u32 {
    if t == types::I32 { TYPE_I32 } else if t == types::I64 { TYPE_I64 }
    else if t == types::F32 { TYPE_F32 } else if t == types::F64 { TYPE_F64 }
    else if t == types::I8 { TYPE_I8 } else if t == types::I16 { TYPE_I16 }
    else { TYPE_I64 }  // default to i64 for unknown types
}
pub fn map_icmp_cond(c: u32) -> IntCC { match c { ICMP_EQ=>IntCC::Equal, ICMP_NE=>IntCC::NotEqual, ICMP_SLT=>IntCC::SignedLessThan, ICMP_SGE=>IntCC::SignedGreaterThanOrEqual, ICMP_SGT=>IntCC::SignedGreaterThan, ICMP_SLE=>IntCC::SignedLessThanOrEqual, ICMP_ULT=>IntCC::UnsignedLessThan, ICMP_UGE=>IntCC::UnsignedGreaterThanOrEqual, ICMP_UGT=>IntCC::UnsignedGreaterThan, ICMP_ULE=>IntCC::UnsignedLessThanOrEqual, _=>IntCC::Equal } }
pub fn map_fcmp_cond(c: u32) -> FloatCC { match c { FCMP_EQ=>FloatCC::Equal, FCMP_NE=>FloatCC::NotEqual, FCMP_LT=>FloatCC::LessThan, FCMP_LE=>FloatCC::LessThanOrEqual, FCMP_GT=>FloatCC::GreaterThan, FCMP_GE=>FloatCC::GreaterThanOrEqual, _=>FloatCC::Equal } }
