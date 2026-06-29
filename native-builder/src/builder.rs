// Builder implementation: Using Cranelift ObjectModule API

use cranelift_codegen::ir::types;
use cranelift_codegen::ir::{AbiParam, Type, Signature, InstBuilder};
use cranelift_codegen::isa::CallConv;
use cranelift_codegen::Context;
use cranelift_frontend::FunctionBuilder;
use cranelift_module::{Linkage, Module};
use cranelift_object::{ObjectBuilder, ObjectModule};
use std::collections::HashMap;
use std::path::Path;
use target_lexicon::Triple;

// Type enums matching Julia's type system
pub const TYPE_I32: u32 = 0;
pub const TYPE_I64: u32 = 1;
pub const TYPE_F32: u32 = 2;
pub const TYPE_F64: u32 = 3;
pub const TYPE_PTR: u32 = 4;

// Main builder context
pub struct BuilderContext {
    functions: Vec<CompiledFunction>,
    current_func_id: usize,
    next_value_id: u32,
    function_builder_context: cranelift_frontend::FunctionBuilderContext,
}

#[derive(Clone)]
struct CompiledFunction {
    name: String,
    signature: Signature,
    ssa_values: HashMap<u32, Type>, // Track SSA value types
}

// Function builder for constructing individual functions
pub struct EdslFunctionBuilder {
    ctx: *mut BuilderContext,
    func_id: usize,
    blocks: Vec<CompiledBlock>,
    current_block_id: usize,
}

struct CompiledBlock {
    name: String,
    instructions: Vec<Instruction>,
    terminator: Option<Terminator>,
}

#[derive(Clone)]
enum Instruction {
    IAdd { result: u32, lhs: u32, rhs: u32 },
    ISub { result: u32, lhs: u32, rhs: u32 },
    IMul { result: u32, lhs: u32, rhs: u32 },
    LoadI32 { result: u32, ptr: u32, offset: i32 },
    LoadI64 { result: u32, ptr: u32, offset: i32 },
    StoreI32 { ptr: u32, offset: i32, value: u32 },
    // More instruction types to be added
}

#[derive(Clone)]
enum Terminator {
    Return { value: u32 },
    Jump { target: u32 },
    BrIf { cond: u32, then_block: u32, else_block: u32 },
}

// Block builder for constructing basic blocks
pub struct BlockBuilder {
    func_builder: *mut EdslFunctionBuilder,
    block_id: usize,
    value_counter: u32,
}

impl BuilderContext {
    pub fn new() -> Self {
        BuilderContext {
            functions: Vec::new(),
            current_func_id: 0,
            next_value_id: 0,
            function_builder_context: cranelift_frontend::FunctionBuilderContext::new(),
        }
    }

    pub fn add_function(
        &mut self,
        name: &str,
        ret_type: u32,
        param_types: &[u32],
    ) -> Option<EdslFunctionBuilder> {
        let signature = self.create_signature(ret_type, param_types);

        let func = CompiledFunction {
            name: name.to_string(),
            signature: signature.clone(),
            ssa_values: HashMap::new(),
        };

        self.functions.push(func);

        // Create a simple EdslFunctionBuilder
        let func_builder = EdslFunctionBuilder {
            ctx: self,
            func_id: self.functions.len() - 1,
            blocks: Vec::new(),
            current_block_id: 0,
        };

        Some(func_builder)
    }

    fn create_signature(&mut self, ret_type: u32, param_types: &[u32]) -> Signature {
        // Use System V calling convention for Linux
        let mut sig = Signature::new(CallConv::SystemV);

        // Add return type
        let ret = self.map_cranelift_type(ret_type);
        if let Some(t) = ret {
            sig.returns.push(AbiParam::new(t));
        }

        // Add parameter types
        for &param_type in param_types {
            let param = self.map_cranelift_type(param_type);
            if let Some(t) = param {
                sig.params.push(AbiParam::new(t));
            }
        }

        sig
    }

    fn map_cranelift_type(&self, type_enum: u32) -> Option<Type> {
        match type_enum {
            TYPE_I32 => Some(types::I32),
            TYPE_I64 => Some(types::I64),
            TYPE_F32 => Some(types::F32),
            TYPE_F64 => Some(types::F64),
            TYPE_PTR => Some(types::I64), // Pointers as i64
            _ => None,
        }
    }

    pub fn finalize(&mut self, output_path: &Path) -> Result<(), String> {
        // Create Target ISA from host triple
        let triple = Triple::host();
        let flags = cranelift_codegen::settings::Flags::new(cranelift_codegen::settings::builder());
        let isa_builder = cranelift_codegen::isa::lookup(triple)
            .map_err(|e| format!("Failed to lookup ISA: {}", e))?;
        let isa = isa_builder.finish(flags)
            .map_err(|e| format!("Failed to create ISA: {}", e))?;

        // Create ObjectBuilder with proper API using default libcall names
        let libcall_namer = Box::new(cranelift_module::default_libcall_names());
        let builder = ObjectBuilder::new(isa, "native_object".to_string(), libcall_namer)
            .map_err(|e| format!("Failed to create ObjectBuilder: {}", e))?;
        let mut module = ObjectModule::new(builder);

        // Compile all functions and add to module
        let func_count = self.functions.len();
        for i in 0..func_count {
            let func = self.functions[i].clone();
            let func_name = func.name.clone();
            let func_signature = func.signature.clone();

            let mut context = Context::new();
            context.func.signature = func_signature.clone();

            // TODO: Convert compiled instructions to Cranelift IR
            // For now, create a minimal function body
            self.emit_function_body(&mut context, &func);

            // Declare the function with signature, not Function
            let func_id = module.declare_function(&func_name, Linkage::Export, &func_signature)
                .map_err(|e| format!("Failed to declare function {}: {}", func_name, e))?;

            module.define_function(func_id, &mut context)
                .map_err(|e| format!("Failed to define function {}: {}", func_name, e))?;
        }

        // Finish and get the object bytes using the proper API
        let product = module.finish();
        let object_bytes = product.emit().map_err(|e| format!("Failed to emit object: {}", e))?;

        // Write object bytes to file
        std::fs::write(output_path, &object_bytes)
            .map_err(|e| format!("Failed to write object file: {}", e))?;

        Ok(())
    }

    fn emit_function_body(&mut self, context: &mut Context, func: &CompiledFunction) {
        // Create a cranelift_frontend::FunctionBuilder to build the function body properly
        let mut func_builder = cranelift_frontend::FunctionBuilder::new(
            &mut context.func,
            &mut self.function_builder_context,
        );

        // Create entry block
        let entry_block = func_builder.create_block();
        func_builder.switch_to_block(entry_block);

        // Append function parameters to the entry block
        func_builder.append_block_params_for_function_params(entry_block);

        // For now, just return a default value based on return type
        // This will be replaced with actual instruction emission from the eDSL later
        let return_type = func.signature.returns.get(0).map(|p| p.value_type);

        if let Some(ret_type) = return_type {
            if ret_type.is_int() {
                if ret_type == types::I64 {
                    let zero = func_builder.ins().iconst(types::I64, 0);
                    func_builder.ins().return_(&[zero]);
                } else if ret_type == types::I32 {
                    let zero = func_builder.ins().iconst(types::I32, 0);
                    func_builder.ins().return_(&[zero]);
                }
            } else if ret_type.is_float() {
                if ret_type == types::F64 {
                    let zero = func_builder.ins().f64const(0.0);
                    func_builder.ins().return_(&[zero]);
                } else if ret_type == types::F32 {
                    let zero = func_builder.ins().f32const(0.0);
                    func_builder.ins().return_(&[zero]);
                }
            }
        } else {
            // Void function - just return
            func_builder.ins().return_(&[]);
        }

        // Seal the block to make it valid
        func_builder.seal_block(entry_block);

        // Declare that we're done building this function
        func_builder.finalize();
    }
}

impl EdslFunctionBuilder {
    pub fn add_block(&mut self, name: &str) -> BlockBuilder {
        let block = CompiledBlock {
            name: name.to_string(),
            instructions: Vec::new(),
            terminator: None,
        };

        self.blocks.push(block);

        BlockBuilder {
            func_builder: self,
            block_id: self.blocks.len() - 1,
            value_counter: 0,
        }
    }
}

impl BlockBuilder {
    pub fn add_iadd(&mut self, lhs: u32, rhs: u32) -> u32 {
        let result_id = self.next_value_id();
        let inst = Instruction::IAdd {
            result: result_id,
            lhs,
            rhs,
        };

        // Add to current block
        let func_builder = unsafe { &mut *self.func_builder };
        func_builder.blocks[self.block_id]
            .instructions
            .push(inst);

        result_id
    }

    pub fn add_return(&mut self, value: u32) {
        let term = Terminator::Return { value };

        // Set terminator for current block
        let func_builder = unsafe { &mut *self.func_builder };
        func_builder.blocks[self.block_id].terminator = Some(term);
    }

    fn next_value_id(&mut self) -> u32 {
        let id = self.value_counter;
        self.value_counter += 1;
        id
    }
}