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
use cranelift_module::{FuncId, Linkage, Module};
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
    ssa_values: HashMap<u32, Value>,
    blocks: HashMap<String, Block>,
    current_block: Block,
    signature: Signature,
    sealed: HashSet<Block>,
    func_name: String,  // original name for declare_function
}

impl FunctionCtx {
    pub fn new(name: &str, ret_type: u32, param_types: &[u32], call_conv: CallConv) -> Option<Self> {
        let mut sig = Signature::new(call_conv);
        if let Some(t) = map_type(ret_type) { sig.returns.push(AbiParam::new(t)); }
        for &pt in param_types {
            if let Some(t) = map_type(pt) { sig.params.push(AbiParam::new(t)); }
        }

        let mut context = Context::new();
        context.func.signature = sig.clone();
        context.func.name = UserFuncName::testcase(name);
        let mut fb_ctx = FunctionBuilderContext::new();
        let mut ssa_values = HashMap::new();

        let entry = {
            let mut fb = FunctionBuilder::new(&mut context.func, &mut fb_ctx);
            let e = fb.create_block();
            fb.switch_to_block(e);
            fb.append_block_params_for_function_params(e);
            drop(fb); e
        };

        for (i, &val) in context.func.dfg.block_params(entry).iter().enumerate() {
            ssa_values.insert(i as u32, val);
        }

        let mut blocks = HashMap::new();
        blocks.insert("block0".to_string(), entry);

        Some(FunctionCtx { context, fb_ctx, ssa_values, blocks,
            current_block: entry, signature: sig, sealed: HashSet::new(),
            func_name: name.to_string() })
    }

    fn ssa(&self, id: u32) -> Value {
        self.ssa_values.get(&id).copied().unwrap_or_else(|| { unsafe { std::mem::transmute::<u32, Value>(0) } })
    }

    fn emit<F: FnOnce(&mut FunctionBuilder) -> Value>(&mut self, f: F) -> u32 {
        let curr = self.current_block;
        let mut fb = FunctionBuilder::new(&mut self.context.func, &mut self.fb_ctx);
        fb.switch_to_block(curr);
        let v = f(&mut fb);
        drop(fb);
        let id = v2u(v);
        self.ssa_values.insert(id, v);
        id
    }

    fn emit_void<F: FnOnce(&mut FunctionBuilder)>(&mut self, f: F) {
        let curr = self.current_block;
        let mut fb = FunctionBuilder::new(&mut self.context.func, &mut self.fb_ctx);
        fb.switch_to_block(curr);
        f(&mut fb);
        drop(fb);
    }

    pub fn create_block_named(&mut self, name: &str) {
        let b = {
            let mut fb = FunctionBuilder::new(&mut self.context.func, &mut self.fb_ctx);
            fb.create_block()
        };
        self.blocks.insert(name.to_string(), b);
    }

    pub fn switch_to_named(&mut self, name: &str) -> bool {
        self.blocks.get(name).map(|&b| { self.current_block = b; true }).unwrap_or(false)
    }

    pub fn seal_block(&mut self, name: &str) {
        if let Some(&b) = self.blocks.get(name) {
            if !self.sealed.contains(&b) {
                let mut fb = FunctionBuilder::new(&mut self.context.func, &mut self.fb_ctx);
                fb.seal_block(b); drop(fb);
                self.sealed.insert(b);
            }
        }
    }

    // --- Constants ---
    pub fn emit_iconst(&mut self, val: i64, ty: u32) -> u32 {
        let t = map_type(ty).unwrap_or(types::I64);
        self.emit(|fb| fb.ins().iconst(t, val))
    }
    pub fn emit_f64const(&mut self, val: f64) -> u32 { self.emit(|fb| fb.ins().f64const(val)) }
    pub fn emit_f32const(&mut self, val: f32) -> u32 { self.emit(|fb| fb.ins().f32const(val)) }

    // --- Arithmetic ---
    pub fn emit_iadd(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().iadd(lv, rv)) }
    pub fn emit_isub(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().isub(lv, rv)) }
    pub fn emit_imul(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().imul(lv, rv)) }
    pub fn emit_sdiv(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().sdiv(lv, rv)) }
    pub fn emit_udiv(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().udiv(lv, rv)) }
    pub fn emit_srem(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().srem(lv, rv)) }
    pub fn emit_urem(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().urem(lv, rv)) }

    // --- Comparisons ---
    pub fn emit_icmp(&mut self, cond: IntCC, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().icmp(cond, lv, rv)) }
    pub fn emit_fcmp(&mut self, cond: FloatCC, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().fcmp(cond, lv, rv)) }
    // select(cond, then, else): returns `then` when cond (a b1 from icmp) is true.
    pub fn emit_select(&mut self, cond: u32, t: u32, e: u32) -> u32 { let (cv, tv, ev) = (self.ssa(cond), self.ssa(t), self.ssa(e)); self.emit(|fb| fb.ins().select(cv, tv, ev)) }

    // --- Bitwise ---
    pub fn emit_band(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().band(lv, rv)) }
    pub fn emit_bor(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().bor(lv, rv)) }
    pub fn emit_bxor(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().bxor(lv, rv)) }
    pub fn emit_ishl(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().ishl(lv, rv)) }
    pub fn emit_ushr(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().ushr(lv, rv)) }
    pub fn emit_sshr(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().sshr(lv, rv)) }

    // --- Conversions ---
    pub fn emit_uextend(&mut self, v: u32, tt: u32) -> u32 { let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::I64); self.emit(|fb| fb.ins().uextend(t, vv)) }
    pub fn emit_sextend(&mut self, v: u32, tt: u32) -> u32 { let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::I64); self.emit(|fb| fb.ins().sextend(t, vv)) }
    pub fn emit_ireduce(&mut self, v: u32, tt: u32) -> u32 { let vv = self.ssa(v); let t = map_type(tt).unwrap_or(types::I32); self.emit(|fb| fb.ins().ireduce(t, vv)) }

    // --- Float ---
    pub fn emit_fadd(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().fadd(lv, rv)) }
    pub fn emit_fsub(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().fsub(lv, rv)) }
    pub fn emit_fmul(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().fmul(lv, rv)) }
    pub fn emit_fdiv(&mut self, l: u32, r: u32) -> u32 { let (lv, rv) = (self.ssa(l), self.ssa(r)); self.emit(|fb| fb.ins().fdiv(lv, rv)) }
    pub fn emit_fneg(&mut self, v: u32) -> u32 { let vv = self.ssa(v); self.emit(|fb| fb.ins().fneg(vv)) }

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
            let mut fb = FunctionBuilder::new(&mut self.context.func, &mut self.fb_ctx);
            fb.append_block_param(b, t)
        };
        let id = v2u(v);
        self.ssa_values.insert(id, v);
        id
    }

    pub fn emit_jump_with_args(&mut self, target: &str, args: &[u32]) {
        let t = *self.blocks.get(target).unwrap_or(&self.current_block);
        let arg_vals: Vec<BlockArg> = args.iter().map(|&a| self.ssa(a).into()).collect();
        let curr = self.current_block;
        self.emit_void(|fb| { fb.ins().jump(t, arg_vals.iter()); });
        self.sealed.insert(curr);
    }

    pub fn emit_jump(&mut self, target: &str) {
        self.emit_jump_with_args(target, &[]);
    }

    pub fn emit_brif_with_args(&mut self, cond: u32, then_s: &str, then_args: &[u32], else_s: &str, else_args: &[u32]) {
        let cv = self.ssa(cond);
        // Reduce to i8 only if needed (icmp already produces i8)
        let cvi8 = {
            let vt = self.context.func.dfg.value_type(cv);
            if vt == types::I8 {
                cv
            } else {
                let curr = self.current_block;
                let mut fb = FunctionBuilder::new(&mut self.context.func, &mut self.fb_ctx);
                fb.switch_to_block(curr);
                let r = fb.ins().ireduce(types::I8, cv);
                drop(fb); r
            }
        };
        let t = *self.blocks.get(then_s).unwrap_or(&self.current_block);
        let e = *self.blocks.get(else_s).unwrap_or(&self.current_block);
        let t_args: Vec<BlockArg> = then_args.iter().map(|&a| self.ssa(a).into()).collect();
        let e_args: Vec<BlockArg> = else_args.iter().map(|&a| self.ssa(a).into()).collect();
        let curr = self.current_block;
        self.emit_void(|fb| { fb.ins().brif(cvi8, t, t_args.iter(), e, e_args.iter()); });
        self.sealed.insert(curr);
    }

    pub fn emit_brif(&mut self, cond: u32, then_s: &str, else_s: &str) {
        self.emit_brif_with_args(cond, then_s, &[], else_s, &[]);
    }
    pub fn emit_return(&mut self, val: u32) {
        let v = self.ssa(val); let curr = self.current_block;
        self.emit_void(|fb| { fb.ins().return_(&[v]); });
        self.sealed.insert(curr);
    }
    pub fn emit_return_void(&mut self) { let curr = self.current_block; self.emit_void(|fb| { fb.ins().return_(&[]); }); self.sealed.insert(curr); }
    pub fn emit_trap(&mut self) { let curr = self.current_block; self.emit_void(|fb| { fb.ins().trap(cranelift_codegen::ir::TrapCode::HEAP_OUT_OF_BOUNDS); }); self.sealed.insert(curr); }

    pub fn emit_call_import(&mut self, module: &mut ObjectModule, imports: &HashMap<String, FuncId>, name: &str, arg_ids: &[u32]) -> u32 {
        let func_id = *imports.get(name).unwrap_or_else(|| panic!("import not declared: {}", name));
        let args: Vec<Value> = arg_ids.iter().map(|&id| self.ssa(id)).collect();
        let curr = self.current_block;
        let mut fb = FunctionBuilder::new(&mut self.context.func, &mut self.fb_ctx);
        fb.switch_to_block(curr);
        let func_ref = module.declare_func_in_func(func_id, &mut fb.func);
        let call = fb.ins().call(func_ref, &args);
        let result = fb.inst_results(call)[0];
        drop(fb);
        let id = v2u(result);
        self.ssa_values.insert(id, result);
        id
    }

    pub fn finalize_ctx(&mut self) -> Result<(), String> {
        let all: Vec<Block> = self.blocks.values().copied().collect();
        for b in all {
            if !self.sealed.contains(&b) {
                let mut fb = FunctionBuilder::new(&mut self.context.func, &mut self.fb_ctx);
                fb.seal_block(b); drop(fb); self.sealed.insert(b);
            }
        }
        let fb = FunctionBuilder::new(&mut self.context.func, &mut self.fb_ctx);
        fb.finalize(); Ok(())
    }
}

// === BuilderContext ===

pub struct BuilderContext {
    module: Option<ObjectModule>,
    pub(crate) funcs: Vec<Box<FunctionCtx>>,
    pub(crate) imports: HashMap<String, FuncId>,
    call_conv: CallConv,
    done: bool,
}

impl BuilderContext {
    pub fn new() -> Self {
        let triple = Triple::host();
        let mut fb = cranelift_codegen::settings::builder();
        fb.set("is_pic", "true").unwrap();  // Required for aarch64 macOS: GOT-based external calls
        let flags = cranelift_codegen::settings::Flags::new(fb);
        let isa = cranelift_codegen::isa::lookup(triple)
            .expect("ISA lookup").finish(flags).expect("ISA finish");
        let call_conv = isa.default_call_conv();
        let lcn = Box::new(cranelift_module::default_libcall_names());
        let ob = ObjectBuilder::new(isa, "obj", lcn).expect("ObjBuilder");
        let module = ObjectModule::new(ob);
        BuilderContext { module: Some(module), funcs: Vec::new(), imports: HashMap::new(), call_conv, done: false }
    }

    pub fn add_function(&mut self, n: &str, rt: u32, pts: &[u32]) -> Option<*mut FunctionCtx> {
        let fc = FunctionCtx::new(n, rt, pts, self.call_conv)?;
        let mut bx = Box::new(fc);
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

    pub fn finalize(&mut self, path: &Path) -> Result<(), String> {
        if self.done { return Err("already finalized".into()); }
        let mut module = self.module.take().ok_or("module already taken")?;
        for f in self.funcs.iter_mut() {
            f.finalize_ctx()?;
            let nm = f.func_name.clone();
            let sig = f.signature.clone();
            eprintln!("[native-builder] declaring: {}", nm);
            let fid = module.declare_function(&nm, Linkage::Export, &sig)
                .map_err(|e| format!("declare {}: {}", nm, e))?;
            module.define_function(fid, &mut f.context)
                .map_err(|e| format!("define {}: {:?}", nm, e))?;
            eprintln!("[native-builder] defined: {}", nm);
        }
        let obj = module.finish().emit().map_err(|e| format!("emit: {}", e))?;
        std::fs::write(path, &obj).map_err(|e| format!("write: {}", e))?;
        self.done = true; Ok(())
    }
}

// === Helpers ===

pub fn map_type(t: u32) -> Option<Type> {
    match t { TYPE_I32=>Some(types::I32), TYPE_I64=>Some(types::I64), TYPE_F32=>Some(types::F32), TYPE_F64=>Some(types::F64), TYPE_PTR=>Some(types::I64), TYPE_I8=>Some(types::I8), _=>None }
}
pub fn map_icmp_cond(c: u32) -> IntCC { match c { ICMP_EQ=>IntCC::Equal, ICMP_NE=>IntCC::NotEqual, ICMP_SLT=>IntCC::SignedLessThan, ICMP_SGE=>IntCC::SignedGreaterThanOrEqual, ICMP_SGT=>IntCC::SignedGreaterThan, ICMP_SLE=>IntCC::SignedLessThanOrEqual, ICMP_ULT=>IntCC::UnsignedLessThan, ICMP_UGE=>IntCC::UnsignedGreaterThanOrEqual, ICMP_UGT=>IntCC::UnsignedGreaterThan, ICMP_ULE=>IntCC::UnsignedLessThanOrEqual, _=>IntCC::Equal } }
pub fn map_fcmp_cond(c: u32) -> FloatCC { match c { FCMP_EQ=>FloatCC::Equal, FCMP_NE=>FloatCC::NotEqual, FCMP_LT=>FloatCC::LessThan, FCMP_LE=>FloatCC::LessThanOrEqual, FCMP_GT=>FloatCC::GreaterThan, FCMP_GE=>FloatCC::GreaterThanOrEqual, _=>FloatCC::Equal } }
