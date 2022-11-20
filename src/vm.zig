const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const t = stdx.testing;
const cy = @import("cyber.zig");
const bindings = @import("bindings.zig");
const Value = cy.Value;
const debug = builtin.mode == .Debug;
const TraceEnabled = @import("build_options").trace;

const log = stdx.log.scoped(.vm);

/// Reserved symbols known at comptime.
pub const ListS: StructId = 0;
pub const MapS: StructId = 1;
pub const ClosureS: StructId = 2;
pub const LambdaS: StructId = 3;
pub const StringS: StructId = 4;

var tempU8Buf: [256]u8 = undefined;

/// Accessing the immediate VM vars is faster when the virtual address is known at compile time.
pub var gvm: VM = undefined;

pub fn getUserVM() UserVM {
    return UserVM{};
}

pub const VM = struct {
    alloc: std.mem.Allocator,
    parser: cy.Parser,
    compiler: cy.VMcompiler,

    /// [Eval context]

    /// Program counter. Index to the next instruction op in `ops`.
    pc: usize,
    /// Current stack frame ptr. Previous stack frame info is saved as a Value after all the reserved locals.
    framePtr: usize,

    ops: []const cy.OpData,
    consts: []const cy.Const,
    strBuf: []const u8,

    /// Value stack.
    stack: stdx.Stack(Value),

    /// Object heap pages.
    heapPages: cy.List(*HeapPage),
    heapFreeHead: ?*HeapObject,

    /// Symbol table used to lookup object methods.
    /// First, the SymbolId indexes into the table for a SymbolMap to lookup the final SymbolEntry by StructId.
    methodSyms: cy.List(SymbolMap),
    methodTable: std.AutoHashMapUnmanaged(MethodKey, SymbolEntry),
    methodSymExtras: cy.List([]const u8),

    /// Used to track which method symbols already exist. Only considers the name right now.
    methodSymSigs: std.StringHashMapUnmanaged(SymbolId),

    /// Regular function symbol table.
    funcSyms: cy.List(FuncSymbolEntry),
    funcSymSignatures: std.StringHashMapUnmanaged(SymbolId),
    funcSymNames: cy.List([]const u8),

    /// Struct fields symbol table.
    fieldSyms: cy.List(FieldSymbolMap),
    fieldSymSignatures: std.StringHashMapUnmanaged(SymbolId),

    /// Structs.
    structs: cy.List(Struct),
    structSignatures: std.StringHashMapUnmanaged(StructId),
    iteratorObjSym: SymbolId,
    pairIteratorObjSym: SymbolId,
    nextObjSym: SymbolId,

    globals: std.StringHashMapUnmanaged(SymbolId),

    u8Buf: cy.List(u8),

    trace: *TraceInfo,
    stackTrace: StackTrace,
    debugTable: []const cy.OpDebug,
    panicMsg: []const u8,

    pub fn init(self: *VM, alloc: std.mem.Allocator) !void {
        self.* = .{
            .alloc = alloc,
            .parser = cy.Parser.init(alloc),
            .compiler = undefined,
            .ops = undefined,
            .consts = undefined,
            .strBuf = undefined,
            .stack = .{},
            .heapPages = .{},
            .heapFreeHead = null,
            .pc = 0,
            .framePtr = 0,
            .methodSymExtras = .{},
            .methodSyms = .{},
            .methodSymSigs = .{},
            .methodTable = .{},
            .funcSyms = .{},
            .funcSymSignatures = .{},
            .funcSymNames = .{},
            .fieldSyms = .{},
            .fieldSymSignatures = .{},
            .structs = .{},
            .structSignatures = .{},
            .iteratorObjSym = undefined,
            .pairIteratorObjSym = undefined,
            .nextObjSym = undefined,
            .trace = undefined,
            .globals = .{},
            .u8Buf = .{},
            .stackTrace = .{},
            .debugTable = undefined,
            .panicMsg = "",
        };
        try self.compiler.init(self);

        // Perform big allocation for hot data paths since the allocator
        // will likely use a more consistent allocation.
        try self.stack.ensureTotalCapacityPrecise(self.alloc, 512);
        try self.methodTable.ensureTotalCapacity(self.alloc, 512);

        // Initialize heap.
        self.heapFreeHead = try self.growHeapPages(1);

        // Core bindings.
        try bindings.bindCore(self);
    }

    pub fn deinit(self: *VM) void {
        self.parser.deinit();
        self.compiler.deinit();
        self.stack.deinit(self.alloc);

        self.methodSyms.deinit(self.alloc);
        self.methodSymExtras.deinit(self.alloc);
        self.methodSymSigs.deinit(self.alloc);
        self.methodTable.deinit(self.alloc);

        self.funcSyms.deinit(self.alloc);
        self.funcSymSignatures.deinit(self.alloc);
        for (self.funcSymNames.items()) |name| {
            self.alloc.free(name);
        }
        self.funcSymNames.deinit(self.alloc);

        self.fieldSyms.deinit(self.alloc);
        self.fieldSymSignatures.deinit(self.alloc);

        for (self.heapPages.items()) |page| {
            self.alloc.destroy(page);
        }
        self.heapPages.deinit(self.alloc);

        self.structs.deinit(self.alloc);
        self.structSignatures.deinit(self.alloc);

        self.globals.deinit(self.alloc);
        self.u8Buf.deinit(self.alloc);
        self.stackTrace.deinit(self.alloc);
        self.alloc.free(self.panicMsg);
    }

    /// Initializes the page with freed object slots and returns the pointer to the first slot.
    fn initHeapPage(page: *HeapPage) *HeapObject {
        // First HeapObject at index 0 is reserved so that freeObject can get the previous slot without a bounds check.
        page.objects[0].common = .{
            .structId = 0, // Non-NullId so freeObject doesn't think it's a free span.
        };
        const first = &page.objects[1];
        first.freeSpan = .{
            .structId = NullId,
            .len = page.objects.len - 1,
            .start = first,
            .next = null,
        };
        // The rest initialize as free spans so checkMemory doesn't think they are retained objects.
        std.mem.set(HeapObject, page.objects[2..], .{
            .common = .{
                .structId = NullId,
            }
        });
        page.objects[page.objects.len-1].freeSpan.start = first;
        return first;
    }

    /// Returns the first free HeapObject.
    fn growHeapPages(self: *VM, numPages: usize) !*HeapObject {
        var idx = self.heapPages.len;
        try self.heapPages.resize(self.alloc, self.heapPages.len + numPages);

        // Allocate first page.
        var page = try self.alloc.create(HeapPage);
        self.heapPages.buf[idx] = page;

        const first = initHeapPage(page);
        var last = first;
        idx += 1;
        while (idx < self.heapPages.len) : (idx += 1) {
            page = try self.alloc.create(HeapPage);
            self.heapPages.buf[idx] = page;
            const first_ = initHeapPage(page);
            last.freeSpan.next = first_;
            last = first_;
        }
        return first;
    }

    pub fn compile(self: *VM, src: []const u8) !cy.ByteCodeBuffer {
        var tt = stdx.debug.trace();
        const astRes = try self.parser.parse(src);
        if (astRes.has_error) {
            log.debug("Parse Error: {s}", .{astRes.err_msg});
            return error.ParseError;
        }
        tt.endPrint("parse");

        tt = stdx.debug.trace();
        const res = try self.compiler.compile(astRes);
        if (res.hasError) {
            log.debug("Compile Error: {s}", .{self.compiler.lastErr});
            return error.CompileError;
        }
        tt.endPrint("compile");

        return res.buf;
    }

    pub fn eval(self: *VM, src: []const u8) !Value {
        var tt = stdx.debug.trace();
        const astRes = try self.parser.parse(src);
        if (astRes.has_error) {
            log.debug("Parse Error: {s}", .{astRes.err_msg});
            return error.ParseError;
        }
        tt.endPrint("parse");

        tt = stdx.debug.trace();
        const res = try self.compiler.compile(astRes);
        if (res.hasError) {
            log.debug("Compile Error: {s}", .{self.compiler.lastErr});
            return error.CompileError;
        }
        tt.endPrint("compile");

        if (TraceEnabled) {
            try res.buf.dump();
            const numOps = @enumToInt(cy.OpCode.end) + 1;
            var opCounts: [numOps]cy.OpCount = undefined;
            self.trace.opCounts = &opCounts;
            var i: u32 = 0;
            while (i < numOps) : (i += 1) {
                self.trace.opCounts[i] = .{
                    .code = i,
                    .count = 0,
                };
            }
            self.trace.totalOpCounts = 0;
            self.trace.numReleases = 0;
            self.trace.numForceReleases = 0;
            self.trace.numRetains = 0;
            self.trace.numRetainCycles = 0;
            self.trace.numRetainCycleRoots = 0;
        }
        tt = stdx.debug.trace();
        defer {
            tt.endPrint("eval");
            if (TraceEnabled) {
                self.dumpInfo();
                const S = struct {
                    fn opCountLess(_: void, a: cy.OpCount, b: cy.OpCount) bool {
                        return a.count > b.count;
                    }
                };
                log.info("total ops evaled: {}", .{self.trace.totalOpCounts});
                std.sort.sort(cy.OpCount, self.trace.opCounts, {}, S.opCountLess);
                var i: u32 = 0;
                const numOps = @enumToInt(cy.OpCode.end) + 1;
                while (i < numOps) : (i += 1) {
                    if (self.trace.opCounts[i].count > 0) {
                        const op = std.meta.intToEnum(cy.OpCode, self.trace.opCounts[i].code) catch continue;
                        log.info("\t{s} {}", .{@tagName(op), self.trace.opCounts[i].count});
                    }
                }
            }
        }

        return self.evalByteCode(res.buf);
    }

    pub fn dumpInfo(self: *VM) void {
        const print = if (builtin.is_test) log.debug else std.debug.print;
        print("stack cap: {}\n", .{self.stack.buf.len});
        print("stack top: {}\n", .{self.stack.top});
        print("heap pages: {}\n", .{self.heapPages.len});

        // Dump object symbols.
        {
            print("obj syms:\n", .{});
            var iter = self.funcSymSignatures.iterator();
            while (iter.next()) |it| {
                print("\t{s}: {}\n", .{it.key_ptr.*, it.value_ptr.*});
            }
        }

        // Dump object fields.
        {
            print("obj fields:\n", .{});
            var iter = self.fieldSymSignatures.iterator();
            while (iter.next()) |it| {
                print("\t{s}: {}\n", .{it.key_ptr.*, it.value_ptr.*});
            }
        }
    }

    pub fn popStackFrameCold(self: *VM, comptime numRetVals: u2) linksection(".eval") void {
        _ = self;
        @setRuntimeSafety(debug);
        switch (numRetVals) {
            2 => {
                log.err("unsupported", .{});
            },
            3 => {
                // unreachable;
            },
            else => @compileError("Unsupported num return values."),
        }
    }

    /// Returns whether to continue execution loop.
    pub fn popStackFrame(self: *VM, comptime numRetVals: u2) linksection(".eval") bool {
        @setRuntimeSafety(debug);

        // If there are fewer return values than required from the function call, 
        // fill the missing slots with the none value.
        switch (numRetVals) {
            0 => {
                @setRuntimeSafety(debug);
                const retInfo = self.stack.buf[self.framePtr];
                const reqNumArgs = retInfo.retInfo.numRetVals;
                if (reqNumArgs == 0) {
                    self.stack.top = self.framePtr;
                    // Restore pc.
                    self.framePtr = retInfo.retInfo.framePtr;
                    self.pc = retInfo.retInfo.pc;
                    return retInfo.retInfo.retFlag == 0;
                } else {
                    switch (reqNumArgs) {
                        0 => unreachable,
                        1 => {
                            @setRuntimeSafety(debug);
                            self.stack.buf[self.framePtr] = Value.initNone();
                            self.stack.top = self.framePtr + 1;
                        },
                        2 => {
                            @setRuntimeSafety(debug);
                            // Only start checking for space after 2 since function calls should have at least one slot after framePtr.
                            self.ensureStackTotalCapacity(self.stack.top + 1) catch stdx.fatal();
                            self.stack.buf[self.framePtr] = Value.initNone();
                            self.stack.buf[self.framePtr+1] = Value.initNone();
                            self.stack.top = self.framePtr + 2;
                        },
                        3 => {
                            @setRuntimeSafety(debug);
                            self.ensureStackTotalCapacity(self.stack.top + 2) catch stdx.fatal();
                            self.stack.buf[self.framePtr] = Value.initNone();
                            self.stack.buf[self.framePtr+1] = Value.initNone();
                            self.stack.buf[self.framePtr+2] = Value.initNone();
                            self.stack.top = self.framePtr + 3;
                        },
                    }
                    // Restore pc.
                    self.framePtr = retInfo.retInfo.framePtr;
                    self.pc = retInfo.retInfo.pc;
                    return retInfo.retInfo.retFlag == 0;
                }
            },
            1 => {
                @setRuntimeSafety(debug);
                const retInfo = self.stack.buf[self.framePtr];
                const reqNumArgs = retInfo.retInfo.numRetVals;
                if (reqNumArgs == 1) {
                    // Copy return value to framePtr.
                    self.stack.buf[self.framePtr] = self.stack.buf[self.stack.top-1];
                    self.stack.top = self.framePtr + 1;

                    // Restore pc.
                    self.framePtr = retInfo.retInfo.framePtr;
                    self.pc = retInfo.retInfo.pc;
                    return retInfo.retInfo.retFlag == 0;
                } else {
                    switch (reqNumArgs) {
                        0 => {
                            @setRuntimeSafety(debug);
                            self.release(self.stack.buf[self.stack.top-1]);
                            self.stack.top = self.framePtr;
                        },
                        1 => unreachable,
                        2 => {
                            @setRuntimeSafety(debug);
                            self.stack.buf[self.framePtr+1] = Value.initNone();
                            self.stack.top = self.framePtr + 2;
                        },
                        3 => {
                            @setRuntimeSafety(debug);
                            // Only start checking for space at 3 since function calls should have at least two slot after framePtr.
                            // self.ensureStackTotalCapacity(self.stack.top + 1) catch stdx.fatal();
                            self.stack.buf[self.framePtr+1] = Value.initNone();
                            self.stack.buf[self.framePtr+2] = Value.initNone();
                            self.stack.top = self.framePtr + 3;
                        },
                    }
                    // Restore pc.
                    self.framePtr = retInfo.retInfo.framePtr;
                    self.pc = retInfo.retInfo.pc;
                    return retInfo.retInfo.retFlag == 0;
                }
            },
            else => @compileError("Unsupported num return values."),
        }
    }

    pub fn evalByteCode(self: *VM, buf: cy.ByteCodeBuffer) !Value {
        if (buf.ops.items.len == 0) {
            return error.NoEndOp;
        }

        self.alloc.free(self.panicMsg);
        self.panicMsg = "";
        self.stack.clearRetainingCapacity();
        self.ops = buf.ops.items;
        self.consts = buf.consts.items;
        self.strBuf = buf.strBuf.items;
        self.debugTable = buf.debugTable.items;
        self.pc = 0;

        try self.ensureStackTotalCapacity(buf.mainLocalSize);
        self.framePtr = 0;
        self.stack.top = buf.mainLocalSize;

        try @call(.{ .modifier = .never_inline }, evalLoopGrowStack, .{});
        if (TraceEnabled) {
            log.info("main local size: {}", .{buf.mainLocalSize});
        }

        if (self.stack.top == buf.mainLocalSize) {
            self.stack.top = 0;
            return Value.initNone();
        } else if (self.stack.top == buf.mainLocalSize + 1) {
            defer self.stack.top = 0;
            return self.popRegister();
        } else {
            log.debug("unexpected stack top: {}, expected: {}", .{self.stack.top, buf.mainLocalSize});
            return error.BadTop;
        }
    }

    fn sliceList(self: *VM, listV: Value, startV: Value, endV: Value) !Value {
        if (listV.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, listV.asPointer().?);
            if (obj.retainedCommon.structId == ListS) {
                const list = stdx.ptrCastAlign(*std.ArrayListUnmanaged(Value), &obj.retainedList.list);
                var start = @floatToInt(i32, startV.toF64());
                if (start < 0) {
                    start = @intCast(i32, list.items.len) + start + 1;
                }
                var end = @floatToInt(i32, endV.toF64());
                if (end < 0) {
                    end = @intCast(i32, list.items.len) + end + 1;
                }
                if (start < 0 or start > list.items.len) {
                    return self.panic("Index out of bounds");
                }
                if (end < start or end > list.items.len) {
                    return self.panic("Index out of bounds");
                }
                return self.allocList(list.items[@intCast(u32, start)..@intCast(u32, end)]);
            } else {
                stdx.panic("expected list");
            }
        } else {
            stdx.panic("expected pointer");
        }
    }

    pub fn allocEmptyMap(self: *VM) !Value {
        const obj = try self.allocObject();
        obj.map = .{
            .structId = MapS,
            .rc = 1,
            .inner = .{
                .metadata = null,
                .entries = null,
                .size = 0,
                .cap = 0,
                .available = 0,
                .extra = 0,
            },
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
        }
        return Value.initPtr(obj);
    }

    fn allocSmallObject(self: *VM, sid: StructId, offsets: []const cy.OpData, props: []const Value) !Value {
        @setRuntimeSafety(debug);
        const obj = try self.allocObject();
        obj.smallObject = .{
            .structId = sid,
            .rc = 1,
            .val0 = undefined,
            .val1 = undefined,
            .val2 = undefined,
            .val3 = undefined,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
        }

        const dst = @ptrCast([*]Value, &obj.smallObject.val0);
        for (offsets) |offset, i| {
            dst[offset.arg] = props[i];
        }

        const res = Value.initPtr(obj);
        return res;
    }

    fn allocMap(self: *VM, keys: []const cy.Const, vals: []const Value) !Value {
        @setRuntimeSafety(debug);
        const obj = try self.allocObject();
        obj.map = .{
            .structId = MapS,
            .rc = 1,
            .inner = .{
                .metadata = null,
                .entries = null,
                .size = 0,
                .cap = 0,
                .available = 0,
                .extra = 0,
            },
        };

        const inner = stdx.ptrCastAlign(*MapInner, &obj.map.inner);
        for (keys) |key, i| {
            const val = vals[i];

            const keyVal = Value{ .val = key.val };
            const res = try inner.getOrPut(self.alloc, self, keyVal);
            if (res.foundExisting) {
                // TODO: Handle reference count.
                res.valuePtr.* = val;
            } else {
                res.valuePtr.* = val;
            }
        }

        const res = Value.initPtr(obj);
        return res;
    }

    fn freeObject(self: *VM, obj: *HeapObject) linksection(".eval") void {
        const prev = &(@ptrCast([*]HeapObject, obj) - 1)[0];
        if (prev.common.structId == NullId) {
            // Left is a free span. Extend length.
            prev.freeSpan.start.freeSpan.len += 1;
            obj.freeSpan.start = prev.freeSpan.start;
        } else {
            // Add single slot free span.
            obj.freeSpan = .{
                .structId = NullId,
                .len = 1,
                .start = obj,
                .next = self.heapFreeHead,
            };
            self.heapFreeHead = obj;
        }
    }

    fn allocObject(self: *VM) !*HeapObject {
        if (self.heapFreeHead == null) {
            self.heapFreeHead = try self.growHeapPages(std.math.max(1, (self.heapPages.len * 15) / 10));
        }
        const ptr = self.heapFreeHead.?;
        if (ptr.freeSpan.len == 1) {
            // This is the only free slot, move to the next free span.
            self.heapFreeHead = ptr.freeSpan.next;
            return ptr;
        } else {
            const next = &@ptrCast([*]HeapObject, ptr)[1];
            next.freeSpan = .{
                .structId = NullId,
                .len = ptr.freeSpan.len - 1,
                .start = next,
                .next = ptr.freeSpan.next,
            };
            const last = &@ptrCast([*]HeapObject, ptr)[ptr.freeSpan.len-1];
            last.freeSpan.start = next;
            self.heapFreeHead = next;
            return ptr;
        }
    }

    fn allocLambda(self: *VM, funcPc: usize, numParams: u8, numLocals: u8) !Value {
        @setRuntimeSafety(debug);
        const obj = try self.allocObject();
        obj.lambda = .{
            .structId = LambdaS,
            .rc = 1,
            .funcPc = @intCast(u32, funcPc),
            .numParams = numParams,
            .numLocals = numLocals,
        };
        return Value.initPtr(obj);
    }

    fn allocClosure(self: *VM, funcPc: usize, numParams: u8, numLocals: u8, capturedVals: []const Value) !Value {
        @setRuntimeSafety(debug);
        const obj = try self.allocObject();
        obj.closure = .{
            .structId = ClosureS,
            .rc = 1,
            .funcPc = @intCast(u32, funcPc),
            .numParams = numParams,
            .numLocals = numLocals,
            .numCaptured = @intCast(u8, capturedVals.len),
            .padding = undefined,
            .capturedVal0 = undefined,
            .capturedVal1 = undefined,
            .extra = undefined,
        };
        switch (capturedVals.len) {
            0 => unreachable,
            1 => {
                obj.closure.capturedVal0 = capturedVals[0];
            },
            2 => {
                obj.closure.capturedVal0 = capturedVals[0];
                obj.closure.capturedVal1 = capturedVals[1];
            },
            3 => {
                obj.closure.capturedVal0 = capturedVals[0];
                obj.closure.capturedVal1 = capturedVals[1];
                obj.closure.extra.capturedVal2 = capturedVals[2];
            },
            else => {
                log.debug("Unsupported number of closure captured values: {}", .{capturedVals.len});
                return error.Panic;
            }
        }
        return Value.initPtr(obj);
    }

    pub fn allocOwnedString(self: *VM, str: []u8) !Value {
        @setRuntimeSafety(debug);
        const obj = try self.allocObject();
        obj.string = .{
            .structId = StringS,
            .rc = 1,
            .ptr = str.ptr,
            .len = str.len,
        };
        return Value.initPtr(obj);
    }

    pub fn allocString(self: *VM, str: []const u8) !Value {
        @setRuntimeSafety(debug);
        const obj = try self.allocObject();
        const dupe = try self.alloc.dupe(u8, str);
        obj.string = .{
            .structId = StringS,
            .rc = 1,
            .ptr = dupe.ptr,
            .len = dupe.len,
        };
        return Value.initPtr(obj);
    }

    pub fn allocStringTemplate(self: *VM, strs: []const Value, vals: []const Value) !Value {
        @setRuntimeSafety(debug);

        const firstStr = self.valueAsString(strs[0]);
        try self.u8Buf.resize(self.alloc, firstStr.len);
        std.mem.copy(u8, self.u8Buf.items(), firstStr);

        var writer = self.u8Buf.writer(self.alloc);
        for (vals) |val, i| {
            self.writeValueToString(writer, val);
            try self.u8Buf.appendSlice(self.alloc, self.valueAsString(strs[i+1]));
        }

        const obj = try self.allocObject();
        const buf = try self.alloc.alloc(u8, self.u8Buf.len);
        std.mem.copy(u8, buf, self.u8Buf.items());
        obj.string = .{
            .structId = StringS,
            .rc = 1,
            .ptr = buf.ptr,
            .len = buf.len,
        };
        return Value.initPtr(obj);
    }

    fn allocStringConcat(self: *VM, str: []const u8, str2: []const u8) !Value {
        @setRuntimeSafety(debug);
        const obj = try self.allocObject();
        const buf = try self.alloc.alloc(u8, str.len + str2.len);
        std.mem.copy(u8, buf[0..str.len], str);
        std.mem.copy(u8, buf[str.len..], str2);
        obj.string = .{
            .structId = StringS,
            .rc = 1,
            .ptr = buf.ptr,
            .len = buf.len,
        };
        return Value.initPtr(obj);
    }

    pub fn allocOwnedList(self: *VM, elems: []Value) !Value {
        @setRuntimeSafety(debug);
        const obj = try self.allocObject();
        obj.retainedList = .{
            .structId = ListS,
            .rc = 1,
            .list = .{
                .ptr = elems.ptr,
                .len = elems.len,
                .cap = elems.len,
            },
            .nextIterIdx = 0,
        };
        return Value.initPtr(obj);
    }

    fn allocList(self: *VM, elems: []const Value) linksection(".eval") !Value {
        @setRuntimeSafety(debug);
        const obj = try self.allocObject();
        obj.retainedList = .{
            .structId = ListS,
            .rc = 1,
            .list = .{
                .ptr = undefined,
                .len = 0,
                .cap = 0,
            },
            .nextIterIdx = 0,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
        }
        const list = stdx.ptrCastAlign(*std.ArrayListUnmanaged(Value), &obj.retainedList.list);
        try list.appendSlice(self.alloc, elems);
        return Value.initPtr(obj);
    }

    inline fn getLocal(self: *const VM, offset: u8) linksection(".eval") Value {
        @setRuntimeSafety(debug);
        return self.stack.buf[self.framePtr + offset];
    }

    inline fn setLocal(self: *const VM, offset: u8, val: Value) linksection(".eval") void {
        @setRuntimeSafety(debug);
        self.stack.buf[self.framePtr + offset] = val;
    }

    pub inline fn popRegister(self: *VM) linksection(".eval") Value {
        @setRuntimeSafety(debug);
        self.stack.top -= 1;
        return self.stack.buf[self.stack.top];
    }

    inline fn ensureStackTotalCapacity(self: *VM, newCap: usize) linksection(".eval") !void {
        if (newCap > self.stack.buf.len) {
            try self.stack.growTotalCapacity(self.alloc, newCap);
        }
    }

    inline fn checkStackHasOneSpace(self: *const VM) linksection(".eval") !void {
        if (self.stack.top == self.stack.buf.len) {
            return error.StackOverflow;
        }
    }

    pub inline fn ensureUnusedStackSpace(self: *VM, unused: u32) linksection(".eval") !void {
        if (self.stack.top + unused > self.stack.buf.len) {
            try self.stack.growTotalCapacity(self.alloc, self.stack.top + unused);
        }
    }

    inline fn pushValueNoCheck(self: *VM, val: Value) linksection(".eval") void {
        @setRuntimeSafety(debug);
        self.stack.buf[self.stack.top] = val;
        self.stack.top += 1;
    }

    pub fn ensureStruct(self: *VM, name: []const u8) !StructId {
        const res = try self.structSignatures.getOrPut(self.alloc, name);
        if (!res.found_existing) {
            return self.addStruct(name);
        } else {
            return res.value_ptr.*;
        }
    }

    pub fn getStructFieldIdx(self: *const VM, sid: StructId, propName: []const u8) ?u32 {
        const fieldId = self.fieldSymSignatures.get(propName) orelse return null;
        const entry = self.fieldSyms.buf[fieldId];
        if (entry.mapT == .oneStruct) {
            if (entry.inner.oneStruct.id == sid) {
                return entry.inner.oneStruct.fieldIdx;
            }
        }
        return null;
    }

    pub inline fn getStruct(self: *const VM, name: []const u8) ?StructId {
        return self.structSignatures.get(name);
    }

    pub fn addStruct(self: *VM, name: []const u8) !StructId {
        const s = Struct{
            .name = name,
            .numFields = 0,
        };
        const id = @intCast(u32, self.structs.len);
        try self.structs.append(self.alloc, s);
        try self.structSignatures.put(self.alloc, name, id);
        return id;
    }

    pub fn ensureGlobalFuncSym(self: *VM, ident: []const u8, funcSymName: []const u8) !void {
        const id = try self.ensureFuncSym(funcSymName);
        try self.globals.put(self.alloc, ident, id);
    }

    pub fn getGlobalFuncSym(self: *VM, ident: []const u8) ?SymbolId {
        return self.globals.get(ident);
    }

    pub inline fn getFuncSym(self: *const VM, name: []const u8) ?SymbolId {
        return self.funcSymSignatures.get(name);
    }
    
    pub fn ensureFuncSym(self: *VM, name: []const u8) !SymbolId {
        const res = try self.funcSymSignatures.getOrPut(self.alloc, name);
        if (!res.found_existing) {
            const id = @intCast(u32, self.funcSyms.len);
            try self.funcSyms.append(self.alloc, .{
                .entryT = .none,
                .inner = undefined,
            });
            res.value_ptr.* = id;
            return id;
        } else {
            return res.value_ptr.*;
        }
    }

    pub fn ensureFieldSym(self: *VM, name: []const u8) !SymbolId {
        const res = try self.fieldSymSignatures.getOrPut(self.alloc, name);
        if (!res.found_existing) {
            const id = @intCast(u32, self.fieldSyms.len);
            try self.fieldSyms.append(self.alloc, .{
                .mapT = .empty,
                .inner = undefined,
                .name = name,
            });
            res.value_ptr.* = id;
            return id;
        } else {
            return res.value_ptr.*;
        }
    }

    pub fn hasMethodSym(self: *const VM, sid: StructId, methodId: SymbolId) bool {
        const map = self.methodSyms.buf[methodId];
        if (map.mapT == .oneStruct) {
            return map.inner.oneStruct.id == sid;
        }
        return false;
    }

    pub fn ensureMethodSymKey(self: *VM, name: []const u8) !SymbolId {
        const res = try self.methodSymSigs.getOrPut(self.alloc, name);
        if (!res.found_existing) {
            const id = @intCast(u32, self.methodSyms.len);
            try self.methodSyms.append(self.alloc, .{
                .mapT = .empty,
                .inner = undefined,
            });
            try self.methodSymExtras.append(self.alloc, name);
            res.value_ptr.* = id;
            return id;
        } else {
            return res.value_ptr.*;
        }
    }

    pub inline fn setFieldSym(self: *VM, sid: StructId, symId: SymbolId, offset: u32, isSmallObject: bool) void {
        self.fieldSyms.buf[symId].mapT = .oneStruct;
        self.fieldSyms.buf[symId].inner = .{
            .oneStruct = .{
                .id = sid,
                .fieldIdx = @intCast(u16, offset),
                .isSmallObject = isSmallObject,
            },
        };
    }

    pub inline fn setFuncSym(self: *VM, symId: SymbolId, sym: FuncSymbolEntry) void {
        self.funcSyms.buf[symId] = sym;
    }

    pub fn addMethodSym(self: *VM, id: StructId, symId: SymbolId, sym: SymbolEntry) !void {
        switch (self.methodSyms.buf[symId].mapT) {
            .empty => {
                self.methodSyms.buf[symId].mapT = .oneStruct;
                self.methodSyms.buf[symId].inner = .{
                    .oneStruct = .{
                        .id = id,
                        .sym = sym,
                    },
                };
            },
            .oneStruct => {
                // Convert to manyStructs.
                var key = MethodKey{
                    .structId = self.methodSyms.buf[symId].inner.oneStruct.id,
                    .methodId = symId,
                };
                self.methodTable.putAssumeCapacityNoClobber(key, self.methodSyms.buf[symId].inner.oneStruct.sym);

                key = .{
                    .structId = id,
                    .methodId = symId,
                };
                self.methodTable.putAssumeCapacityNoClobber(key, sym);

                self.methodSyms.buf[symId].mapT = .manyStructs;
                self.methodSyms.buf[symId].inner = .{
                    .manyStructs = .{
                        .mruStructId = id,
                        .mruSym = sym,
                    },
                };
            },
            .manyStructs => {
                const key = MethodKey{
                    .structId = id,
                    .methodId = symId,
                };
                self.methodTable.putAssumeCapacityNoClobber(key, sym);
            },
            // else => stdx.panicFmt("unsupported {}", .{self.methodSyms.buf[symId].mapT}),
        }
    }

    fn setIndex(self: *VM, left: Value, index: Value, right: Value) !void {
        @setRuntimeSafety(debug);
        if (left.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, left.asPointer().?);
            switch (obj.retainedCommon.structId) {
                ListS => {
                    const list = stdx.ptrCastAlign(*std.ArrayListUnmanaged(Value), &obj.retainedList.list);
                    const idx = @floatToInt(u32, index.toF64());
                    if (idx < list.items.len) {
                        list.items[idx] = right;
                    } else {
                        // var i: u32 = @intCast(u32, list.val.items.len);
                        // try list.val.resize(self.alloc, idx + 1);
                        // while (i < idx) : (i += 1) {
                        //     list.val.items[i] = Value.none();
                        // }
                        // list.val.items[idx] = right;
                        return self.panic("Index out of bounds.");
                    }
                },
                MapS => {
                    const map = stdx.ptrCastAlign(*MapInner, &obj.map.inner);
                    try map.put(self.alloc, self, index, right);
                },
                else => {
                    return stdx.panic("unsupported struct");
                },
            }
        } else {
            return stdx.panic("expected pointer");
        }
    }

    fn getReverseIndex(self: *const VM, left: Value, index: Value) !Value {
        @setRuntimeSafety(debug);
        if (left.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, left.asPointer().?);
            switch (obj.retainedCommon.structId) {
                ListS => {
                    @setRuntimeSafety(debug);
                    const list = stdx.ptrCastAlign(*std.ArrayListUnmanaged(Value), &obj.retainedList.list);
                    const idx = list.items.len - @floatToInt(u32, index.toF64());
                    if (idx < list.items.len) {
                        return list.items[idx];
                    } else {
                        return error.OutOfBounds;
                    }
                },
                MapS => {
                    @setRuntimeSafety(debug);
                    const map = stdx.ptrCastAlign(*MapInner, &obj.map.inner);
                    const key = Value.initF64(-index.toF64());
                    if (map.get(self, key)) |val| {
                        return val;
                    } else return Value.initNone();
                },
                else => {
                    stdx.panic("expected map or list");
                },
            }
        } else {
            return stdx.panic("expected pointer");
        }
    }

    fn getIndex(self: *VM, left: Value, index: Value) !Value {
        @setRuntimeSafety(debug);
        if (left.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, left.asPointer().?);
            switch (obj.retainedCommon.structId) {
                ListS => {
                    @setRuntimeSafety(debug);
                    const list = stdx.ptrCastAlign(*std.ArrayListUnmanaged(Value), &obj.retainedList.list);
                    const idx = @floatToInt(u32, index.toF64());
                    if (idx < list.items.len) {
                        return list.items[idx];
                    } else {
                        return error.OutOfBounds;
                    }
                },
                MapS => {
                    @setRuntimeSafety(debug);
                    const map = stdx.ptrCastAlign(*MapInner, &obj.map.inner);
                    if (map.get(self, index)) |val| {
                        return val;
                    } else return Value.initNone();
                },
                else => {
                    return stdx.panic("expected map or list");
                },
            }
        } else {
            return stdx.panic("expected pointer");
        }
    }

    fn panic(self: *VM, comptime msg: []const u8) error{Panic, OutOfMemory} {
        @setCold(true);
        @setRuntimeSafety(debug);
        self.panicMsg = try self.alloc.dupe(u8, msg);
        return error.Panic;
    }

    /// Performs an iteration over the heap pages to check whether there are retain cycles.
    pub fn checkMemory(self: *VM) !bool {
        var nodes: std.AutoHashMapUnmanaged(*HeapObject, RcNode) = .{};
        defer nodes.deinit(self.alloc);

        var cycleRoots: std.ArrayListUnmanaged(*HeapObject) = .{};
        defer cycleRoots.deinit(self.alloc);

        // No concept of root vars yet. Just report any existing retained objects.
        // First construct the graph.
        for (self.heapPages.items()) |page| {
            for (page.objects[1..]) |*obj| {
                if (obj.common.structId != NullId) {
                    try nodes.put(self.alloc, obj, .{
                        .visited = false,
                        .entered = false,
                    });
                }
            }
        }
        const S = struct {
            fn visit(alloc: std.mem.Allocator, graph: *std.AutoHashMapUnmanaged(*HeapObject, RcNode), cycleRoots_: *std.ArrayListUnmanaged(*HeapObject), obj: *HeapObject, node: *RcNode) bool {
                if (node.visited) {
                    return false;
                }
                if (node.entered) {
                    return true;
                }
                node.entered = true;

                switch (obj.retainedCommon.structId) {
                    ListS => {
                        const list = stdx.ptrCastAlign(*std.ArrayListUnmanaged(Value), &obj.retainedList.list);
                        for (list.items) |it| {
                            if (it.isPointer()) {
                                const ptr = stdx.ptrCastAlign(*HeapObject, it.asPointer().?);
                                if (visit(alloc, graph, cycleRoots_, ptr, graph.getPtr(ptr).?)) {
                                    cycleRoots_.append(alloc, obj) catch stdx.fatal();
                                    return true;
                                }
                            }
                        }
                    },
                    else => {
                    },
                }
                node.entered = false;
                node.visited = true;
                return false;
            }
        };
        var iter = nodes.iterator();
        while (iter.next()) |*entry| {
            if (S.visit(self.alloc, &nodes, &cycleRoots, entry.key_ptr.*, entry.value_ptr)) {
                if (TraceEnabled) {
                    self.trace.numRetainCycles = 1;
                    self.trace.numRetainCycleRoots = @intCast(u32, cycleRoots.items.len);
                }
                for (cycleRoots.items) |root| {
                    // Force release.
                    self.forceRelease(root);
                }
                return false;
            }
        }
        return true;
    }

    pub inline fn retain(self: *const VM, val: Value) void {
        @setRuntimeSafety(debug);
        if (val.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, val.asPointer());
            obj.retainedCommon.rc += 1;
            if (TraceEnabled) {
                self.trace.numRetains += 1;
            }
        }
    }

    pub fn forceRelease(self: *VM, obj: *HeapObject) void {
        if (TraceEnabled) {
            self.trace.numForceReleases += 1;
        }
        switch (obj.retainedCommon.structId) {
            ListS => {
                const list = stdx.ptrCastAlign(*std.ArrayListUnmanaged(Value), &obj.retainedList.list);
                list.deinit(self.alloc);
                self.freeObject(obj);
            },
            MapS => {
                const map = stdx.ptrCastAlign(*MapInner, &obj.map.inner);
                map.deinit(self.alloc);
                self.freeObject(obj);
            },
            else => {
                return stdx.panic("unsupported struct type");
            },
        }
    }

    pub fn release(self: *VM, val: Value) linksection(".eval") void {
        @setRuntimeSafety(debug);
        // log.info("release", .{});
        // val.dump();
        if (val.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, val.asPointer().?);
            obj.retainedCommon.rc -= 1;
            if (TraceEnabled) {
                self.trace.numReleases += 1;
            }
            if (obj.retainedCommon.rc == 0) {
                switch (obj.retainedCommon.structId) {
                    ListS => {
                        const list = stdx.ptrCastAlign(*std.ArrayListUnmanaged(Value), &obj.retainedList.list);
                        for (list.items) |it| {
                            self.release(it);
                        }
                        list.deinit(self.alloc);
                        self.freeObject(obj);
                    },
                    MapS => {
                        const map = stdx.ptrCastAlign(*MapInner, &obj.map.inner);
                        var iter = map.iterator();
                        while (iter.next()) |entry| {
                            self.release(entry.key);
                            self.release(entry.value);
                        }
                        map.deinit(self.alloc);
                        self.freeObject(obj);
                    },
                    ClosureS => {
                        if (obj.closure.numCaptured <= 3) {
                            const src = @ptrCast([*]Value, &obj.closure.capturedVal0)[0..obj.closure.numCaptured];
                            for (src) |capturedVal| {
                                self.release(capturedVal);
                            }
                            self.freeObject(obj);
                        } else {
                            stdx.panic("unsupported");
                        }
                    },
                    LambdaS => {
                        self.freeObject(obj);
                    },
                    StringS => {
                        self.alloc.free(obj.string.ptr[0..obj.string.len]);
                        self.freeObject(obj);
                    },
                    else => {
                        // Struct deinit.
                        if (builtin.mode == .Debug) {
                            // Check range.
                            if (obj.retainedCommon.structId >= self.structs.len) {
                                log.debug("unsupported struct type {}", .{obj.retainedCommon.structId});
                                stdx.fatal();
                            }
                        }
                        const numFields = self.structs.buf[obj.retainedCommon.structId].numFields;
                        if (numFields <= 4) {
                            for (obj.smallObject.getValuesConstPtr()[0..numFields]) |child| {
                                self.release(child);
                            }
                            self.freeObject(obj);
                        } else {
                            log.debug("unsupported release big object", .{});
                            stdx.fatal();
                        }
                    },
                }
            }
        }
    }

    fn releaseSetField(self: *VM, recv: Value, fieldId: SymbolId, val: Value) linksection(".eval") !void {
        @setRuntimeSafety(debug);
        if (recv.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, recv.asPointer());
            const symMap = self.fieldSyms.buf[fieldId];
            switch (symMap.mapT) {
                .oneStruct => {
                    @setRuntimeSafety(debug);
                    if (obj.common.structId == symMap.inner.oneStruct.id) {
                        if (symMap.inner.oneStruct.isSmallObject) {
                            self.release(obj.smallObject.getValuesPtr()[symMap.inner.oneStruct.fieldIdx]);
                            obj.smallObject.getValuesPtr()[symMap.inner.oneStruct.fieldIdx] = val;
                        } else {
                            stdx.panic("TODO: big object");
                        }
                    } else {
                        stdx.panic("TODO: set field fallback");
                    }
                },
                .manyStructs => {
                    @setRuntimeSafety(debug);
                    stdx.fatal();
                },
                .empty => {
                    @setRuntimeSafety(debug);
                    stdx.panic("TODO: set field fallback");
                },
            } 
        } else {
            try self.setFieldNotObjectError();
        }
    }

    fn setField(self: *VM, recv: Value, fieldId: SymbolId, val: Value) linksection(".eval") !void {
        @setRuntimeSafety(debug);
        if (recv.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, recv.asPointer());
            const symMap = self.fieldSyms.buf[fieldId];
            switch (symMap.mapT) {
                .oneStruct => {
                    @setRuntimeSafety(debug);
                    if (obj.common.structId == symMap.inner.oneStruct.id) {
                        if (symMap.inner.oneStruct.isSmallObject) {
                            obj.smallObject.getValuesPtr()[symMap.inner.oneStruct.fieldIdx] = val;
                        } else {
                            stdx.panic("TODO: big object");
                        }
                    } else {
                        stdx.panic("TODO: set field fallback");
                    }
                },
                .manyStructs => {
                    @setRuntimeSafety(debug);
                    stdx.fatal();
                },
                .empty => {
                    @setRuntimeSafety(debug);
                    stdx.panic("TODO: set field fallback");
                },
            } 
        } else {
            try self.setFieldNotObjectError();
        }
    }

    fn getFieldMissingSymbolError(self: *VM) !void {
        @setCold(true);
        return self.panic("Field not found in value.");
    }

    fn setFieldNotObjectError(self: *VM) !void {
        @setCold(true);
        return self.panic("Can't assign to value's field since the value is not an object.");
    }

    fn getAndRetainField(self: *const VM, symId: SymbolId, recv: Value) linksection(".eval") Value {
        @setRuntimeSafety(debug);
        if (recv.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, recv.asPointer());
            const symMap = self.fieldSyms.buf[symId];
            switch (symMap.mapT) {
                .oneStruct => {
                    if (obj.retainedCommon.structId == symMap.inner.oneStruct.id) {
                        if (symMap.inner.oneStruct.isSmallObject) {
                            const val = obj.smallObject.getValuesConstPtr()[symMap.inner.oneStruct.fieldIdx];
                            self.retain(val);
                            return val;
                        } else {
                            stdx.panic("TODO: big object");
                        }
                    } else {
                        return self.getFieldOther(obj, symMap.name);
                    }
                },
                .manyStructs => {
                    @setRuntimeSafety(debug);
                    stdx.fatal();
                },
                .empty => {
                    return self.getFieldOther(obj, symMap.name);
                },
            } 
        } else {
            unreachable;
        }
    }

    fn getField(self: *VM, symId: SymbolId, recv: Value) linksection(".eval") !Value {
        @setRuntimeSafety(debug);
        if (recv.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, recv.asPointer());
            const symMap = self.fieldSyms.buf[symId];
            switch (symMap.mapT) {
                .oneStruct => {
                    if (obj.common.structId == symMap.inner.oneStruct.id) {
                        if (symMap.inner.oneStruct.isSmallObject) {
                            return obj.smallObject.getValuesConstPtr()[symMap.inner.oneStruct.fieldIdx];
                        } else {
                            stdx.panic("TODO: big object");
                        }
                    } else {
                        return self.getFieldOther(obj, symMap.name);
                    }
                },
                .manyStructs => {
                    @setRuntimeSafety(debug);
                    stdx.fatal();
                },
                .empty => {
                    return self.getFieldOther(obj, symMap.name);
                },
                // else => {
                //     // stdx.panicFmt("unsupported {}", .{symMap.mapT});
                //     unreachable;
                // },
            } 
        } else {
            try self.getFieldMissingSymbolError();
            unreachable;
        }
    }

    fn getFieldOther(self: *const VM, obj: *const HeapObject, name: []const u8) linksection(".eval") Value {
        @setCold(true);
        if (obj.common.structId == MapS) {
            const map = stdx.ptrCastAlign(*const MapInner, &obj.map.inner);
            if (map.getByString(self, name)) |val| {
                return val;
            } else return Value.initNone();
        } else {
            log.debug("Missing symbol for object: {}", .{obj.common.structId});
            return Value.initNone();
        }
    }

    /// Stack layout: arg0, arg1, ..., callee
    /// numArgs includes the callee.
    pub fn call(self: *VM, callee: Value, numArgs: u8, retInfo: Value) !void {
        @setRuntimeSafety(debug);
        if (callee.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, callee.asPointer().?);
            switch (obj.common.structId) {
                ClosureS => {
                    if (numArgs - 1 != obj.closure.numParams) {
                        stdx.panic("params/args mismatch");
                    }

                    if (self.stack.top + obj.closure.numLocals >= self.stack.buf.len) {
                        return error.StackOverflow;
                    }

                    self.pc = obj.closure.funcPc;
                    self.framePtr = self.stack.top - numArgs;
                    self.stack.buf[self.framePtr] = retInfo;
                    self.stack.top += obj.lambda.numLocals;

                    // Copy over captured vars to new call stack locals.
                    if (obj.closure.numCaptured <= 3) {
                        const src = @ptrCast([*]Value, &obj.closure.capturedVal0)[0..obj.closure.numCaptured];
                        std.mem.copy(Value, self.stack.buf[self.stack.top-obj.closure.numCaptured..self.stack.top], src);
                    } else {
                        stdx.panic("unsupported closure > 3 captured args.");
                    }
                },
                LambdaS => {
                    if (numArgs - 1 != obj.lambda.numParams) {
                        log.debug("params/args mismatch {} {}", .{numArgs, obj.lambda.numParams});
                        stdx.fatal();
                    }

                    if (self.stack.top + obj.lambda.numLocals >= self.stack.buf.len) {
                        return error.StackOverflow;
                    }

                    self.pc = obj.lambda.funcPc;
                    self.framePtr = self.stack.top - numArgs;
                    self.stack.buf[self.framePtr] = retInfo;
                    self.stack.top += obj.lambda.numLocals;
                },
                else => {},
            }
        } else {
            stdx.panic("not a function");
        }
    }

    /// Current stack top is already pointing past the last arg.
    fn callSym(self: *VM, symId: SymbolId, numArgs: u8, comptime reqNumRetVals: u2) linksection(".eval") !void {
        @setRuntimeSafety(debug);
        const sym = self.funcSyms.buf[symId];
        switch (sym.entryT) {
            .nativeFunc1 => {
                @setRuntimeSafety(debug);
                self.pc += 3;
                const args = self.stack.buf[self.stack.top - numArgs..self.stack.top];
                const res = sym.inner.nativeFunc1(.{}, args.ptr, @intCast(u8, args.len));
                if (reqNumRetVals == 1) {
                    const newTop = self.stack.top - numArgs + 1;
                    if (newTop >= self.stack.buf.len) {
                        // Already made state changes, so grow stack here instead of
                        // returning StackOverflow.
                        try self.stack.growTotalCapacity(self.alloc, newTop);
                    }
                    self.stack.top = newTop;
                    self.stack.buf[self.stack.top-1] = res;
                } else {
                    switch (reqNumRetVals) {
                        0 => {
                            self.stack.top = self.stack.top - numArgs;
                        },
                        1 => stdx.panic("not possible"),
                        2 => {
                            stdx.panic("unsupported require 2 ret vals");
                        },
                        3 => {
                            stdx.panic("unsupported require 3 ret vals");
                        },
                    }
                }
            },
            .func => {
                @setRuntimeSafety(debug);
                if (self.stack.top + sym.inner.func.numLocals >= self.stack.buf.len) {
                    return error.StackOverflow;
                }

                const retInfo = self.buildReturnInfo2(self.pc + 3, reqNumRetVals, true);
                self.pc = sym.inner.func.pc;
                self.framePtr = self.stack.top - numArgs;

                // Move first arg. 
                const retInfoDst = &self.stack.buf[self.framePtr];
                self.stack.buf[self.stack.top] = retInfoDst.*;
                // Set retInfo last so it will copy over any undefined value for zero arg func calls.
                retInfoDst.* = retInfo;

                self.stack.top += sym.inner.func.numLocals;
            },
            // .none => {
            //     // Function doesn't exist.
            //     log.debug("Symbol {} doesn't exist.", .{symId});
            //     // TODO: script panic.
            //     return error.MissingSymbol;
            // },
            else => {
                log.debug("unsupported callsym", .{});
                stdx.fatal();
            },
        }
    }

    fn callSymEntry(self: *VM, sym: SymbolEntry, obj: *HeapObject, numArgs: u8, comptime reqNumRetVals: u2) linksection(".eval") !void {
        @setRuntimeSafety(debug);
        const argStart = self.stack.top - numArgs;
        switch (sym.entryT) {
            .func => {
                @setRuntimeSafety(debug);
                if (self.stack.top + sym.inner.func.numLocals >= self.stack.buf.len) {
                    return error.StackOverflow;
                }

                // Retain receiver.
                obj.retainedCommon.rc += 1;

                // const retInfo = self.buildReturnInfo2(self.pc + 3, reqNumRetVals, true);
                const retInfo = self.buildReturnInfo(reqNumRetVals, true);
                self.pc = sym.inner.func.pc;
                self.framePtr = self.stack.top - numArgs;

                // Move first arg. 
                const retInfoDst = &self.stack.buf[self.framePtr];
                self.stack.buf[self.stack.top] = retInfoDst.*;
                // Set retInfo last so it will copy over any undefined value for zero arg func calls.
                retInfoDst.* = retInfo;

                self.stack.top += sym.inner.func.numLocals;
            },
            .nativeFunc1 => {
                @setRuntimeSafety(debug);
                // self.pc += 3;
                const args = self.stack.buf[argStart .. self.stack.top - 1];
                const res = sym.inner.nativeFunc1(.{}, obj, args.ptr, @intCast(u8, args.len));
                if (reqNumRetVals == 1) {
                    self.stack.buf[argStart] = res;
                    self.stack.top = argStart + 1;
                } else {
                    switch (reqNumRetVals) {
                        0 => {
                            self.stack.top = argStart;
                        },
                        1 => stdx.panic("not possible"),
                        2 => {
                            stdx.panic("unsupported require 2 ret vals");
                        },
                        3 => {
                            stdx.panic("unsupported require 3 ret vals");
                        },
                    }
                }
            },
            .nativeFunc2 => {
                @setRuntimeSafety(debug);
                // self.pc += 3;
                const args = self.stack.buf[argStart .. self.stack.top - 1];
                const func = @ptrCast(std.meta.FnPtr(fn (*VM, *anyopaque, []const Value) cy.ValuePair), sym.inner.nativeFunc2);
                const res = func(self, obj, args);
                if (reqNumRetVals == 2) {
                    self.stack.buf[argStart] = res.left;
                    self.stack.buf[argStart+1] = res.right;
                    self.stack.top = argStart + 2;
                } else {
                    switch (reqNumRetVals) {
                        0 => {
                            self.stack.top = argStart;
                        },
                        1 => unreachable,
                        2 => {
                            unreachable;
                        },
                        3 => {
                            unreachable;
                        },
                    }
                }
            },
            // else => {
            //     // stdx.panicFmt("unsupported {}", .{sym.entryT});
            //     unreachable;
            // },
        }
    }

    fn callObjSymOther(self: *VM, obj: *const HeapObject, symId: SymbolId, numArgs: u8, comptime reqNumRetVals: u2) !void {
        @setCold(true);
        @setRuntimeSafety(debug);
        const name = self.methodSymExtras.buf[symId];
        if (obj.common.structId == MapS) {
            const heapMap = stdx.ptrCastAlign(*const MapInner, &obj.map.inner);
            if (heapMap.getByString(self, name)) |val| {
                // Replace receiver with function.
                self.stack.buf[self.stack.top-1] = val;
                // const retInfo = self.buildReturnInfo2(self.pc + 3, reqNumRetVals, true);
                const retInfo = self.buildReturnInfo(reqNumRetVals, true);
                self.call(val, numArgs, retInfo) catch stdx.fatal();
                return;
            }
        }
        return self.panic("Missing function symbol in value");
    }

    fn getCallObjSym(self: *VM, obj: *HeapObject, symId: SymbolId) linksection(".eval") ?SymbolEntry {
        @setRuntimeSafety(debug);
        const map = self.methodSyms.buf[symId];
        switch (map.mapT) {
            .oneStruct => {
                @setRuntimeSafety(debug);
                if (obj.retainedCommon.structId == map.inner.oneStruct.id) {
                    return map.inner.oneStruct.sym;
                } else return null;
            },
            .manyStructs => {
                @setRuntimeSafety(debug);
                if (map.inner.manyStructs.mruStructId == obj.retainedCommon.structId) {
                    return map.inner.manyStructs.mruSym;
                } else {
                    const sym = self.methodTable.get(.{ .structId = obj.retainedCommon.structId, .methodId = symId }) orelse return null;
                    self.methodSyms.buf[symId].inner.manyStructs = .{
                        .mruStructId = obj.retainedCommon.structId,
                        .mruSym = sym,
                    };
                    return sym;
                }
            },
            .empty => {
                @setRuntimeSafety(debug);
                return null;
            },
            // else => {
            //     unreachable;
            //     // stdx.panicFmt("unsupported {}", .{map.mapT});
            // },
        } 
    }

    /// Stack layout: arg0, arg1, ..., receiver
    /// numArgs includes the receiver.
    fn callObjSym(self: *VM, recv: Value, symId: SymbolId, numArgs: u8, comptime reqNumRetVals: u2) linksection(".eval") !void {
        @setRuntimeSafety(debug);
        if (recv.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, recv.asPointer().?);
            const map = self.methodSyms.buf[symId];
            switch (map.mapT) {
                .oneStruct => {
                    @setRuntimeSafety(debug);
                    if (obj.retainedCommon.structId == map.inner.oneStruct.id) {
                        try self.callSymEntry(map.inner.oneStruct.sym, obj, numArgs, reqNumRetVals);
                    } else return self.panic("Symbol does not exist for receiver.");
                },
                .manyStructs => {
                    @setRuntimeSafety(debug);
                    if (map.inner.manyStructs.mruStructId == obj.retainedCommon.structId) {
                        try self.callSymEntry(map.inner.manyStructs.mruSym, obj, numArgs, reqNumRetVals);
                    } else {
                        const sym = self.methodTable.get(.{ .structId = obj.retainedCommon.structId, .methodId = symId }) orelse {
                            log.debug("Symbol does not exist for receiver.", .{});
                            stdx.fatal();
                        };
                        self.methodSyms.buf[symId].inner.manyStructs = .{
                            .mruStructId = obj.retainedCommon.structId,
                            .mruSym = sym,
                        };
                        try self.callSymEntry(sym, obj, numArgs, reqNumRetVals);
                    }
                },
                .empty => {
                    @setRuntimeSafety(debug);
                    try self.callObjSymOther(obj, symId, numArgs, reqNumRetVals);
                },
                // else => {
                //     unreachable;
                //     // stdx.panicFmt("unsupported {}", .{map.mapT});
                // },
            } 
        }
    }

    pub inline fn buildReturnInfo2(self: *const VM, pc: usize, comptime numRetVals: u2, comptime cont: bool) linksection(".eval") Value {
        @setRuntimeSafety(debug);
        return Value{
            .retInfo = .{
                .pc = @intCast(u32, pc),
                .framePtr = @intCast(u29, self.framePtr),
                .numRetVals = numRetVals,
                .retFlag = if (cont) 0 else 1,
            },
        };
    }

    pub inline fn buildReturnInfo(self: *const VM, comptime numRetVals: u2, comptime cont: bool) linksection(".eval") Value {
        @setRuntimeSafety(debug);
        return Value{
            .retInfo = .{
                .pc = @intCast(u32, self.pc),
                .framePtr = @intCast(u29, self.framePtr),
                .numRetVals = numRetVals,
                .retFlag = if (cont) 0 else 1,
            },
        };
    }

    pub fn getStackTrace(self: *const VM) *const StackTrace {
        return &self.stackTrace;
    }

    fn indexOfDebugSym(self: *const VM, pc: usize) ?usize {
        for (self.debugTable) |sym, i| {
            if (sym.pc == pc) {
                return i;
            }
        }
        return null;
    }

    fn computeLinePos(self: *const VM, loc: u32, outLine: *u32, outCol: *u32) void {
        var line: u32 = 0;
        var lineStart: u32 = 0;
        for (self.compiler.tokens) |token| {
            if (token.token_t == .new_line) {
                line += 1;
                lineStart = token.start_pos + 1;
                continue;
            }
            if (token.start_pos == loc) {
                outLine.* = line;
                outCol.* = loc - lineStart;
                return;
            }
        }
    }

    pub fn buildStackTrace(self: *VM) !void {
        self.stackTrace.deinit(self.alloc);
        var frames: std.ArrayListUnmanaged(StackFrame) = .{};

        var framePtr = self.framePtr;
        var pc = self.pc;
        while (true) {
            const idx = self.indexOfDebugSym(pc) orelse return error.NoDebugSym;
            const sym = self.debugTable[idx];

            if (sym.frameLoc == NullId) {
                const node = self.compiler.nodes[sym.loc];
                var line: u32 = undefined;
                var col: u32 = undefined;
                self.computeLinePos(self.compiler.tokens[node.start_token].start_pos, &line, &col);
                try frames.append(self.alloc, .{
                    .name = "main",
                    .line = line,
                    .col = col,
                });
                break;
            } else {
                const frameNode = self.compiler.nodes[sym.frameLoc];
                const func = self.compiler.funcDecls[frameNode.head.func.decl_id];
                const name = self.compiler.src[func.name.start..func.name.end];

                const node = self.compiler.nodes[sym.loc];
                var line: u32 = undefined;
                var col: u32 = undefined;
                self.computeLinePos(self.compiler.tokens[node.start_token].start_pos, &line, &col);
                try frames.append(self.alloc, .{
                    .name = name,
                    .line = line,
                    .col = col,
                });
                pc = self.stack.buf[framePtr].retInfo.pc;
                framePtr = self.stack.buf[framePtr].retInfo.framePtr;
            }
        }

        self.stackTrace.frames = frames.toOwnedSlice(self.alloc);
    }

    fn evalLoop(self: *VM) linksection(".eval") error{StackOverflow, OutOfMemory, Panic, OutOfBounds, NoDebugSym, End}!void {
        @setRuntimeSafety(debug);
        while (true) {
            if (TraceEnabled) {
                const op = self.ops[self.pc].code;
                self.trace.opCounts[@enumToInt(op)].count += 1;
                self.trace.totalOpCounts += 1;
            }
            if (builtin.mode == .Debug) {
                switch (self.ops[self.pc].code) {
                    .pushCallObjSym0 => {
                        const methodId = self.ops[self.pc+1].arg;
                        const numArgs = self.ops[self.pc+2].arg;
                        log.debug("{} op: {s} {} {}", .{self.pc, @tagName(self.ops[self.pc].code), methodId, numArgs});
                    },
                    .pushCallSym1 => {
                        const funcId = self.ops[self.pc+1].arg;
                        const numArgs = self.ops[self.pc+2].arg;
                        log.debug("{} op: {s} {} {}", .{self.pc, @tagName(self.ops[self.pc].code), funcId, numArgs});
                    },
                    .pushCallSym0 => {
                        const funcId = self.ops[self.pc+1].arg;
                        const numArgs = self.ops[self.pc+2].arg;
                        log.debug("{} op: {s} {} {}", .{self.pc, @tagName(self.ops[self.pc].code), funcId, numArgs});
                    },
                    .release => {
                        const local = self.ops[self.pc+1].arg;
                        log.debug("{} op: {s} {}", .{self.pc, @tagName(self.ops[self.pc].code), local});
                    },
                    .load => {
                        const local = self.ops[self.pc+1].arg;
                        log.debug("{} op: {s} {}", .{self.pc, @tagName(self.ops[self.pc].code), local});
                    },
                    .pushFieldRetain => {
                        const fieldId = self.ops[self.pc+1].arg;
                        log.debug("{} op: {s} {}", .{self.pc, @tagName(self.ops[self.pc].code), fieldId});
                    },
                    .pushMap => {
                        const numEntries = self.ops[self.pc+1].arg;
                        const startConst = self.ops[self.pc+2].arg;
                        log.debug("{} op: {s} {} {}", .{self.pc, @tagName(self.ops[self.pc].code), numEntries, startConst});
                    },
                    .pushConst => {
                        const idx = self.ops[self.pc+1].arg;
                        const val = Value{ .val = self.consts[idx].val };
                        log.debug("{} op: {s} [{s}]", .{self.pc, @tagName(self.ops[self.pc].code), self.valueToTempString(val)});
                    },
                    .setInitN => {
                        const numLocals = self.ops[self.pc+1].arg;
                        const locals = self.ops[self.pc+2..self.pc+2+numLocals];
                        log.debug("{} op: {s} {}", .{self.pc, @tagName(self.ops[self.pc].code), numLocals});
                        for (locals) |local| {
                            log.debug("{}", .{local.arg});
                        }
                    },
                    else => {
                        log.debug("{} op: {s}", .{self.pc, @tagName(self.ops[self.pc].code)});
                    },
                }
            }
            switch (self.ops[self.pc].code) {
                .pushTrue => {
                    @setRuntimeSafety(debug);
                    try self.checkStackHasOneSpace();
                    self.pc += 1;
                    self.pushValueNoCheck(Value.initTrue());
                    continue;
                },
                .pushFalse => {
                    @setRuntimeSafety(debug);
                    try self.checkStackHasOneSpace();
                    self.pc += 1;
                    self.pushValueNoCheck(Value.initFalse());
                    continue;
                },
                .pushNone => {
                    @setRuntimeSafety(debug);
                    try self.checkStackHasOneSpace();
                    self.pc += 1;
                    self.pushValueNoCheck(Value.initNone());
                    continue;
                },
                .pushConst => {
                    @setRuntimeSafety(debug);
                    try self.checkStackHasOneSpace();
                    const idx = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    self.pushValueNoCheck(Value.initRaw(self.consts[idx].val));
                    continue;
                },
                .pushStringTemplate => {
                    @setRuntimeSafety(debug);
                    const exprCount = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const count = exprCount * 2 + 1;
                    const strs = self.stack.buf[self.stack.top-count..self.stack.top-exprCount];
                    const vals = self.stack.buf[self.stack.top-exprCount..self.stack.top];
                    const res = try @call(.{ .modifier = .never_inline }, self.allocStringTemplate, .{strs, vals});
                    self.stack.top = self.stack.top - count + 1;
                    self.stack.buf[self.stack.top-1] = res;
                    continue;
                },
                .pushNeg => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    const val = self.stack.buf[self.stack.top-1];
                    self.stack.buf[self.stack.top-1] = evalNeg(val);
                    continue;
                },
                .pushNot => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    const val = self.stack.buf[self.stack.top-1];
                    self.stack.buf[self.stack.top-1] = evalNot(val);
                    continue;
                },
                .pushNotCompare => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const right = self.stack.buf[self.stack.top];
                    const left = self.stack.buf[self.stack.top-1];
                    if (left.isNumber()) {
                        self.stack.buf[self.stack.top-1] = evalNotCompareNumber(left, right);
                    } else {
                        self.stack.buf[self.stack.top-1] = @call(.{.modifier = .never_inline }, evalNotCompareOther, .{self, left, right});
                    }
                    continue;
                },
                .pushCompare => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const right = self.stack.buf[self.stack.top];
                    const left = self.stack.buf[self.stack.top-1];
                    if (left.isNumber()) {
                        self.stack.buf[self.stack.top-1] = evalCompareNumber(left, right);
                    } else {
                        self.stack.buf[self.stack.top-1] = @call(.{.modifier = .never_inline }, evalCompareOther, .{self, left, right});
                    }
                    continue;
                },
                .pushLess => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const right = self.stack.buf[self.stack.top];
                    const left = self.stack.buf[self.stack.top-1];
                    self.stack.buf[self.stack.top-1] = evalLess(left, right);
                    continue;
                },
                .pushGreater => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const right = self.stack.buf[self.stack.top];
                    const left = self.stack.buf[self.stack.top-1];
                    self.stack.buf[self.stack.top-1] = evalGreater(left, right);
                    continue;
                },
                .pushLessEqual => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const right = self.stack.buf[self.stack.top];
                    const left = self.stack.buf[self.stack.top-1];
                    self.stack.buf[self.stack.top-1] = evalLessOrEqual(left, right);
                    continue;
                },
                .pushGreaterEqual => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const right = self.stack.buf[self.stack.top];
                    const left = self.stack.buf[self.stack.top-1];
                    self.stack.buf[self.stack.top-1] = evalGreaterOrEqual(left, right);
                    continue;
                },
                .pushBitwiseAnd => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const right = self.stack.buf[self.stack.top];
                    const left = self.stack.buf[self.stack.top-1];
                    self.stack.buf[self.stack.top-1] = evalBitwiseAnd(left, right);
                    continue;
                },
                .pushAdd => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const left = self.stack.buf[self.stack.top-1];
                    const right = self.stack.buf[self.stack.top];
                    if (left.isNumber() and right.isNumber()) {
                        self.stack.buf[self.stack.top-1] = evalAddNumber(left, right);
                    } else {
                        self.stack.buf[self.stack.top-1] = try evalAddFallback(self, left, right);
                    }
                    continue;
                },
                .pushMinus => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const left = self.stack.buf[self.stack.top-1];
                    const right = self.stack.buf[self.stack.top];
                    self.stack.buf[self.stack.top-1] = evalMinus(left, right);
                    continue;
                },
                .pushMinus1 => {
                    @setRuntimeSafety(debug);
                    const leftOffset = self.ops[self.pc+1].arg;
                    const rightOffset = self.ops[self.pc+2].arg;
                    self.pc += 3;

                    if (leftOffset == NullByteId) {
                        const left = self.stack.buf[self.stack.top-1];
                        const right = self.getLocal(rightOffset);
                        self.stack.buf[self.stack.top-1] = evalMinus(left, right);
                        continue;
                    } else {
                        const left = self.getLocal(leftOffset);
                        const right = self.stack.buf[self.stack.top-1];
                        self.stack.buf[self.stack.top-1] = evalMinus(left, right);
                        continue;
                    }
                },
                .pushMinus2 => {
                    @setRuntimeSafety(debug);
                    try self.checkStackHasOneSpace();
                    const leftOffset = self.ops[self.pc+1].arg;
                    const rightOffset = self.ops[self.pc+2].arg;
                    self.pc += 3;

                    const left = self.getLocal(leftOffset);
                    const right = self.getLocal(rightOffset);
                    self.pushValueNoCheck(@call(.{ .modifier = .never_inline }, evalMinus, .{left, right}));
                    continue;
                },
                .pushList => {
                    @setRuntimeSafety(debug);
                    const numElems = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const elems = self.stack.buf[self.stack.top-numElems..self.stack.top];
                    const list = try self.allocList(elems);
                    self.stack.top = self.stack.top - numElems + 1;
                    self.stack.buf[self.stack.top-1] = list;
                    continue;
                },
                .pushMapEmpty => {
                    @setRuntimeSafety(debug);
                    try self.checkStackHasOneSpace();
                    self.pc += 1;

                    const map = try self.allocEmptyMap();
                    self.pushValueNoCheck(map);
                    continue;
                },
                .pushStructInitSmall => {
                    @setRuntimeSafety(debug);
                    try self.checkStackHasOneSpace();
                    const sid = self.ops[self.pc+1].arg;
                    const numProps = self.ops[self.pc+2].arg;
                    const offsets = self.ops[self.pc+3..self.pc+3+numProps];
                    self.pc += 3 + numProps;

                    const props = self.stack.buf[self.stack.top - numProps..self.stack.top];
                    const obj = try self.allocSmallObject(sid, offsets, props);
                    self.stack.top = self.stack.top - numProps + 1;
                    self.stack.buf[self.stack.top-1] = obj;
                    continue;
                },
                .pushMap => {
                    @setRuntimeSafety(debug);
                    const numEntries = self.ops[self.pc+1].arg;
                    const startConst = self.ops[self.pc+2].arg;
                    self.pc += 3;

                    const keys = self.consts[startConst..startConst+numEntries];
                    const vals = self.stack.buf[self.stack.top-numEntries..self.stack.top];
                    self.stack.top = self.stack.top-numEntries+1;

                    const map = try self.allocMap(keys, vals);
                    self.stack.buf[self.stack.top-1] = map;
                    continue;
                },
                .pushSlice => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 2;
                    const end = self.stack.buf[self.stack.top+1];
                    const start = self.stack.buf[self.stack.top];
                    const list = self.stack.buf[self.stack.top-1];
                    const newList = try self.sliceList(list, start, end);
                    self.stack.buf[self.stack.top-1] = newList;
                    continue;
                },
                .addSet => {
                    @setRuntimeSafety(debug);
                    const offset = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const val = self.popRegister();

                    const left = self.getLocal(offset);
                    if (left.isNumber() and val.isNumber()) {
                        self.setLocal(offset, evalAddNumber(left, val));
                    } else {
                        self.setLocal(offset, try evalAddFallback(self, left, val));
                    }
                    continue;
                },
                .releaseSet => {
                    @setRuntimeSafety(debug);
                    const offset = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const val = self.popRegister();
                    const existing = self.getLocal(offset);
                    self.release(existing);
                    self.setLocal(offset, val);
                    continue;
                },
                .setInitN => {
                    @setRuntimeSafety(debug);
                    const numLocals = self.ops[self.pc+1].arg;
                    const locals = self.ops[self.pc+2..self.pc+2+numLocals];
                    self.pc += 2 + numLocals;
                    for (locals) |local| {
                        self.setLocal(local.arg, Value.initNone());
                    }
                },
                .set => {
                    @setRuntimeSafety(debug);
                    const offset = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const val = self.popRegister();
                    self.setLocal(offset, val);
                    continue;
                },
                .setIndex => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 3;
                    const right = self.stack.buf[self.stack.top+2];
                    const index = self.stack.buf[self.stack.top+1];
                    const left = self.stack.buf[self.stack.top];
                    try self.setIndex(left, index, right);
                    continue;
                },
                .load => {
                    @setRuntimeSafety(debug);
                    try self.checkStackHasOneSpace();
                    const offset = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const val = self.getLocal(offset);
                    self.pushValueNoCheck(val);
                    continue;
                },
                .loadRetain => {
                    @setRuntimeSafety(debug);
                    try self.checkStackHasOneSpace();
                    const offset = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const val = self.getLocal(offset);
                    self.pushValueNoCheck(val);
                    self.retain(val);
                    continue;
                },
                .pushIndex => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const index = self.stack.buf[self.stack.top];
                    const left = self.stack.buf[self.stack.top-1];
                    const val = try @call(.{.modifier = .never_inline}, self.getIndex, .{left, index});
                    self.stack.buf[self.stack.top - 1] = val;
                    continue;
                },
                .pushReverseIndex => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const index = self.stack.buf[self.stack.top];
                    const left = self.stack.buf[self.stack.top-1];
                    const val = try @call(.{.modifier = .never_inline}, self.getReverseIndex, .{left, index});
                    self.stack.buf[self.stack.top - 1] = val;
                    continue;
                },
                .jumpBack => {
                    @setRuntimeSafety(debug);
                    self.pc -= @ptrCast(*const align(1) u16, &self.ops[self.pc+1]).*;
                    continue;
                },
                .jump => {
                    @setRuntimeSafety(debug);
                    self.pc += @ptrCast(*const align(1) u16, &self.ops[self.pc+1]).*;
                    continue;
                },
                .jumpNotCondKeep => {
                    @setRuntimeSafety(debug);
                    const pcOffset = @ptrCast(*const align(1) u16, &self.ops[self.pc+1]).*;
                    const expr = self.stack.buf[self.stack.top-1];
                    const condVal = if (expr.isBool()) b: {
                        break :b expr.asBool();
                    } else b: {
                        break :b @call(.{ .modifier = .never_inline }, expr.toBool, .{});
                    };
                    if (!condVal) {
                        self.pc += pcOffset;
                    } else {
                        self.pc += 3;
                        self.stack.top -= 1;
                    }
                    continue;
                },
                .jumpCondKeep => {
                    @setRuntimeSafety(debug);
                    const pcOffset = @ptrCast(*const align(1) u16, &self.ops[self.pc+1]).*;
                    const expr = self.stack.buf[self.stack.top-1];
                    const condVal = if (expr.isBool()) b: {
                        break :b expr.asBool();
                    } else b: {
                        break :b @call(.{ .modifier = .never_inline }, expr.toBool, .{});
                    };
                    if (condVal) {
                        self.pc += pcOffset;
                    } else {
                        self.pc += 3;
                        self.stack.top -= 1;
                    }
                    continue;
                },
                .jumpNotCond => {
                    @setRuntimeSafety(debug);
                    const pcOffset = @ptrCast(*const align(1) u16, &self.ops[self.pc+1]).*;
                    const cond = self.popRegister();
                    const condVal = if (cond.isBool()) b: {
                        break :b cond.asBool();
                    } else b: {
                        break :b @call(.{ .modifier = .never_inline }, cond.toBool, .{});
                    };
                    if (!condVal) {
                        self.pc += pcOffset;
                    } else {
                        self.pc += 3;
                    }
                    continue;
                },
                .release => {
                    @setRuntimeSafety(debug);
                    const local = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    // TODO: Inline if heap object.
                    @call(.{ .modifier = .never_inline }, self.release, .{self.getLocal(local)});
                    continue;
                },
                .pushCall0 => {
                    @setRuntimeSafety(debug);
                    const numArgs = self.ops[self.pc+1].arg;
                    self.pc += 2;

                    const callee = self.stack.buf[self.stack.top - numArgs];
                    const retInfo = self.buildReturnInfo(0, true);
                    try @call(.{ .modifier = .never_inline }, self.call, .{callee, numArgs, retInfo});
                    continue;
                },
                .pushCall1 => {
                    @setRuntimeSafety(debug);
                    const numArgs = self.ops[self.pc+1].arg;
                    self.pc += 2;

                    const callee = self.stack.buf[self.stack.top - numArgs];
                    const retInfo = self.buildReturnInfo(1, true);
                    try @call(.{ .modifier = .never_inline }, self.call, .{callee, numArgs, retInfo});
                    continue;
                },
                .call => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    continue;
                },
                .callStr => {
                    @setRuntimeSafety(debug);
                    // const numArgs = self.ops[self.pc+1].arg;
                    // const str = self.extras[self.extraPc].two;
                    self.pc += 3;

                    // const top = self.registers.items.len;
                    // const vals = self.registers.items[top-numArgs..top];
                    // self.registers.items.len = top-numArgs;

                    // self.callStr(vals[0], self.strBuf[str[0]..str[1]], vals[1..]);
                    continue;
                },
                .pushCallObjSym0 => {
                    @setRuntimeSafety(debug);
                    const symId = self.ops[self.pc+1].arg;
                    const numArgs = self.ops[self.pc+2].arg;
                    self.pc += 3;

                    const recv = self.stack.buf[self.stack.top-1];
                    if (recv.isPointer()) {
                        const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer().?);
                        if (self.getCallObjSym(obj, symId)) |sym| {
                            try self.callSymEntry(sym, obj, numArgs, 0);
                            // self.callSymEntry, .{sym, obj, numArgs, 0});
                        } else {
                            try @call(.{ .modifier = .never_inline }, self.callObjSymOther, .{obj, symId, numArgs, 0});
                        }
                    } else {
                        return self.panic("Missing function symbol in value.");
                    }
                    // try self.callObjSym(recv, symId, numArgs, 0);
                    // try @call(.{.modifier = .always_inline }, self.callObjSym, .{recv, symId, numArgs, 0});
                    continue;
                },
                .pushCallObjSym1 => {
                    @setRuntimeSafety(debug);
                    const symId = self.ops[self.pc+1].arg;
                    const numArgs = self.ops[self.pc+2].arg;
                    self.pc += 3;

                    const recv = self.stack.buf[self.stack.top-1];
                    if (recv.isPointer()) {
                        const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer().?);
                        if (self.getCallObjSym(obj, symId)) |sym| {
                            try self.callSymEntry(sym, obj, numArgs, 1);
                            // try @call(.{ .modifier = .always_inline }, self.callSymEntry, .{sym, obj, numArgs, 1});
                        } else {
                            try @call(.{ .modifier = .never_inline }, self.callObjSymOther, .{obj, symId, numArgs, 1});
                        }
                    } else {
                        return self.panic("Missing function symbol in value.");
                    }
                    // try self.callObjSym(recv, symId, numArgs, 1);
                    // try @call(.{.modifier = .always_inline }, self.callObjSym, .{recv, symId, numArgs, 1});
                    continue;
                },
                .pushCallSym0 => {
                    @setRuntimeSafety(debug);
                    const symId = self.ops[self.pc+1].arg;
                    const numArgs = self.ops[self.pc+2].arg;

                    try self.callSym(symId, numArgs, 0);
                    // try @call(.{ .modifier = .always_inline }, self.callSym, .{ symId, vals, false });
                    continue;
                },
                .pushCallSym1 => {
                    @setRuntimeSafety(debug);
                    const symId = self.ops[self.pc+1].arg;
                    const numArgs = self.ops[self.pc+2].arg;

                    try self.callSym(symId, numArgs, 1);
                    // try @call(.{ .modifier = .always_inline }, self.callSym, .{ symId, vals, true });
                    continue;
                },
                .releaseSetField => {
                    @setRuntimeSafety(debug);
                    const fieldId = self.ops[self.pc+1].arg;
                    self.pc += 2;

                    const recv = self.stack.buf[self.stack.top-2];
                    const val = self.stack.buf[self.stack.top-1];
                    self.stack.top -= 2;
                    try self.releaseSetField(recv, fieldId, val);
                },
                .setField => {
                    @setRuntimeSafety(debug);
                    const fieldId = self.ops[self.pc+1].arg;
                    self.pc += 2;

                    const recv = self.stack.buf[self.stack.top-2];
                    const val = self.stack.buf[self.stack.top-1];
                    self.stack.top -= 2;
                    try self.setField(recv, fieldId, val);
                },
                .pushFieldParentRelease => {
                    @setRuntimeSafety(debug);
                    const fieldId = self.ops[self.pc+1].arg;
                    self.pc += 2;

                    const recv = self.stack.buf[self.stack.top-1];
                    const val = try self.getField(fieldId, recv);
                    self.stack.buf[self.stack.top-1] = val;
                    self.release(recv);
                    continue;
                },
                .pushField => {
                    @setRuntimeSafety(debug);
                    const fieldId = self.ops[self.pc+1].arg;
                    self.pc += 2;

                    const recv = self.stack.buf[self.stack.top-1];
                    const val = try self.getField(fieldId, recv);
                    self.stack.buf[self.stack.top-1] = val;
                    continue;
                },
                .pushFieldRetainParentRelease => {
                    @setRuntimeSafety(debug);
                    const fieldId = self.ops[self.pc+1].arg;
                    self.pc += 2;

                    const recv = self.stack.buf[self.stack.top-1];
                    const val = self.getAndRetainField(fieldId, recv);
                    self.stack.buf[self.stack.top-1] = val;
                    self.release(recv);
                    continue;
                },
                .pushFieldRetain => {
                    @setRuntimeSafety(debug);
                    const fieldId = self.ops[self.pc+1].arg;
                    self.pc += 2;

                    const recv = self.stack.buf[self.stack.top-1];
                    const val = self.getAndRetainField(fieldId, recv);
                    self.stack.buf[self.stack.top-1] = val;
                    continue;
                },
                .pushLambda => {
                    @setRuntimeSafety(debug);
                    try self.checkStackHasOneSpace();
                    const funcPc = self.pc - self.ops[self.pc+1].arg;
                    const numParams = self.ops[self.pc+2].arg;
                    const numLocals = self.ops[self.pc+3].arg;
                    self.pc += 4;

                    const lambda = try self.allocLambda(funcPc, numParams, numLocals);
                    self.pushValueNoCheck(lambda);
                    continue;
                },
                .pushClosure => {
                    @setRuntimeSafety(debug);
                    const funcPc = self.pc - self.ops[self.pc+1].arg;
                    const numParams = self.ops[self.pc+2].arg;
                    const numCaptured = self.ops[self.pc+3].arg;
                    const numLocals = self.ops[self.pc+4].arg;
                    self.pc += 5;

                    const capturedVals = self.stack.buf[self.stack.top-numCaptured..self.stack.top];
                    const closure = try self.allocClosure(funcPc, numParams, numLocals, capturedVals);
                    self.stack.top = self.stack.top-numCaptured+1;
                    self.stack.buf[self.stack.top-1] = closure;
                    continue;
                },
                .forIter => {
                    @setRuntimeSafety(debug);
                    const local = self.ops[self.pc+1].arg;
                    self.pc += 3;

                    const val = self.stack.buf[self.stack.top-1];
                    try self.callObjSym(val, self.iteratorObjSym, 1, 1);
                    const recv = self.stack.buf[self.stack.top-1];
                    if (!recv.isPointer()) {
                        return self.panic("Not an iterator.");
                    }
                    if (local == 255) {
                        while (true) {
                            // try self.callObjSym(recv, self.nextObjSym, 1, 1);
                            // try @call(.{ .modifier = .never_inline }, self.callObjSym, .{recv, self.nextObjSym, 1, 1});
                            const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer().?);
                            if (self.getCallObjSym(obj, self.nextObjSym)) |sym| {
                                try self.callSymEntry(sym, obj, 1, 1);
                            } else return self.panic("Missing function symbol in value.");

                            const next = self.stack.buf[self.stack.top-1];
                            if (next.isNone()) {
                                break;
                            }
                            @call(.{ .modifier = .never_inline }, evalLoopGrowStack, .{}) catch |err| {
                                if (err == error.BreakLoop) {
                                    break;
                                } else return err;
                            };
                        }
                    } else {
                        while (true) {
                            // try self.callObjSym(recv, self.nextObjSym, 1, 1);
                            // try @call(.{ .modifier = .never_inline }, self.callObjSym, .{recv, self.nextObjSym, 1, 1});
                            const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer().?);
                            if (self.getCallObjSym(obj, self.nextObjSym)) |sym| {
                                try self.callSymEntry(sym, obj, 1, 1);
                            } else return self.panic("Missing function symbol in value.");

                            const next = self.stack.buf[self.stack.top-1];
                            if (next.isNone()) {
                                break;
                            }
                            self.setLocal(local, next);
                            @call(.{ .modifier = .never_inline }, evalLoopGrowStack, .{}) catch |err| {
                                if (err == error.BreakLoop) {
                                    break;
                                } else return err;
                            };
                        }
                    }
                    self.release(recv);
                    self.stack.top -= 1;
                    self.pc = self.pc + self.ops[self.pc-1].arg - 3;
                    continue;
                },
                .forRange => {
                    @setRuntimeSafety(debug);
                    const local = self.ops[self.pc+1].arg;
                    const endPc = self.pc + self.ops[self.pc+2].arg;
                    self.pc += 3;

                    self.stack.top -= 3;
                    const step = self.stack.buf[self.stack.top+2].toF64();
                    const rangeEnd = self.stack.buf[self.stack.top+1].toF64();
                    var i = self.stack.buf[self.stack.top].toF64();

                    if (i <= rangeEnd) {
                        if (local == 255) {
                            while (i < rangeEnd) : (i += step) {
                                @call(.{ .modifier = .never_inline }, evalLoopGrowStack, .{}) catch |err| {
                                    if (err == error.BreakLoop) {
                                        break;
                                    } else return err;
                                };
                            }
                        } else {
                            while (i < rangeEnd) : (i += step) {
                                self.setLocal(local, Value.initF64(i));
                                @call(.{ .modifier = .never_inline }, evalLoopGrowStack, .{}) catch |err| {
                                    if (err == error.BreakLoop) {
                                        break;
                                    } else return err;
                                };
                            }
                        }
                    } else {
                        if (local == 255) {
                            while (i > rangeEnd) : (i -= step) {
                                @call(.{ .modifier = .never_inline }, evalLoopGrowStack, .{}) catch |err| {
                                    if (err == error.BreakLoop) {
                                        break;
                                    } else return err;
                                };
                            }
                        } else {
                            while (i > rangeEnd) : (i -= step) {
                                self.setLocal(local, Value.initF64(i));
                                @call(.{ .modifier = .never_inline }, evalLoopGrowStack, .{}) catch |err| {
                                    if (err == error.BreakLoop) {
                                        break;
                                    } else return err;
                                };
                            }
                        }
                    }
                    self.pc = endPc;
                    continue;
                },
                .cont => {
                    @setRuntimeSafety(debug);
                    self.pc -= @ptrCast(*const align(1) u16, &self.ops[self.pc+1]).*;
                    return;
                },
                // .ret2 => {
                //     @setRuntimeSafety(debug);
                //     // Using never_inline seems to work against the final compiler optimizations.
                //     // @call(.{ .modifier = .never_inline }, self.popStackFrameCold, .{2});
                //     self.popStackFrameCold(2);
                //     continue;
                // },
                .ret1 => {
                    @setRuntimeSafety(debug);
                    if (@call(.{ .modifier = .always_inline }, self.popStackFrame, .{1})) {
                        continue;
                    } else {
                        return;
                    }
                },
                .ret0 => {
                    @setRuntimeSafety(debug);
                    if (@call(.{ .modifier = .always_inline }, self.popStackFrame, .{0})) {
                        continue;
                    } else {
                        return;
                    }
                },
                .pushMultiply => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const left = self.stack.buf[self.stack.top-1];
                    const right = self.stack.buf[self.stack.top];
                    self.stack.buf[self.stack.top-1] = @call(.{ .modifier = .never_inline }, evalMultiply, .{left, right});
                    continue;
                },
                .pushDivide => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const left = self.stack.buf[self.stack.top-1];
                    const right = self.stack.buf[self.stack.top];
                    self.stack.buf[self.stack.top-1] = @call(.{ .modifier = .never_inline }, evalDivide, .{left, right});
                    continue;
                },
                .pushMod => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const left = self.stack.buf[self.stack.top-1];
                    const right = self.stack.buf[self.stack.top];
                    self.stack.buf[self.stack.top-1] = @call(.{ .modifier = .never_inline }, evalMod, .{left, right});
                    continue;
                },
                .pushPower => {
                    @setRuntimeSafety(debug);
                    self.pc += 1;
                    self.stack.top -= 1;
                    const left = self.stack.buf[self.stack.top-1];
                    const right = self.stack.buf[self.stack.top];
                    self.stack.buf[self.stack.top-1] = @call(.{ .modifier = .never_inline }, evalPower, .{left, right});
                    continue;
                },
                .end => {
                    return error.End;
                },
            }
        }
    }

    pub fn valueAsString(self: *const VM, val: Value) []const u8 {
        @setRuntimeSafety(debug);
        if (val.isPointer()) {
            const obj = stdx.ptrCastAlign(*HeapObject, val.asPointer().?);
            return obj.string.ptr[0..obj.string.len];
        } else {
            // Assume const string.
            const slice = val.asConstStr();
            return self.strBuf[slice.start..slice.end];
        }
    }

    /// Conversion goes into a temporary buffer. Must use the result before a subsequent call.
    pub fn valueToTempString(self: *const VM, val: Value) linksection(".eval2") []const u8 {
        if (val.isNumber()) {
            const f = val.asF64();
            if (Value.floatCanBeInteger(f)) {
                return std.fmt.bufPrint(&tempU8Buf, "{d:.0}", .{f}) catch stdx.fatal();
            } else {
                return std.fmt.bufPrint(&tempU8Buf, "{d:.10}", .{f}) catch stdx.fatal();
            }
        } else {
            if (val.isPointer()) {
                const obj = stdx.ptrCastAlign(*HeapObject, val.asPointer().?);
                if (obj.common.structId == StringS) {
                    return obj.string.ptr[0..obj.string.len];
                } else {
                    return self.structs.buf[obj.common.structId].name;
                }
            } else {
                switch (val.getTag()) {
                    cy.TagBoolean => {
                        if (val.asBool()) return "true" else return "false";
                    },
                    cy.TagNone => return "none",
                    cy.TagConstString => {
                        // Convert into heap string.
                        const slice = val.asConstStr();
                        return self.strBuf[slice.start..slice.end];
                    },
                    else => {
                        log.debug("unexpected tag {}", .{val.getTag()});
                        stdx.fatal();
                    },
                }
            }
        }
    }

    fn writeValueToString(self: *const VM, writer: anytype, val: Value) void {
        if (val.isNumber()) {
            const f = val.asF64();
            if (Value.floatIsSpecial(f)) {
                std.fmt.format(writer, "{}", .{f}) catch stdx.fatal();
            } else {
                if (Value.floatCanBeInteger(f)) {
                    std.fmt.format(writer, "{}", .{@floatToInt(u64, f)}) catch stdx.fatal();
                } else {
                    std.fmt.format(writer, "{d:.10}", .{f}) catch stdx.fatal();
                }
            }
        } else {
            if (val.isPointer()) {
                const obj = stdx.ptrCastAlign(*HeapObject, val.asPointer().?);
                if (obj.common.structId == StringS) {
                    const str = obj.string.ptr[0..obj.string.len];
                    _ = writer.write(str) catch stdx.fatal();
                } else {
                    log.debug("unexpected struct {}", .{obj.common.structId});
                    stdx.fatal();
                }
            } else {
                switch (val.getTag()) {
                    cy.TagBoolean => {
                        if (val.asBool()) {
                            _ = writer.write("true") catch stdx.fatal();
                        } else {
                            _ = writer.write("false") catch stdx.fatal();
                        }
                    },
                    cy.TagNone => {
                        _ = writer.write("none") catch stdx.fatal();
                    },
                    cy.TagConstString => {
                        // Convert into heap string.
                        const slice = val.asConstStr();
                        _ = writer.write(self.strBuf[slice.start..slice.end]) catch stdx.fatal();
                    },
                    else => {
                        log.debug("unexpected tag {}", .{val.getTag()});
                        stdx.fatal();
                    },
                }
            }
        }
    }
};

fn evalBitwiseAnd(left: Value, right: Value) Value {
    @setRuntimeSafety(debug);
    if (left.isNumber()) {
       const f = @intToFloat(f64, left.asI32() & @floatToInt(i32, right.toF64()));
       return Value.initF64(f);
    } else {
        log.debug("unsupported", .{});
        unreachable;
    }
}

fn evalGreaterOrEqual(left: cy.Value, right: cy.Value) cy.Value {
    return Value.initBool(left.toF64() >= right.toF64());
}

fn evalGreater(left: cy.Value, right: cy.Value) cy.Value {
    return Value.initBool(left.toF64() > right.toF64());
}

fn evalLessOrEqual(left: cy.Value, right: cy.Value) cy.Value {
    return Value.initBool(left.toF64() <= right.toF64());
}

fn evalLess(left: cy.Value, right: cy.Value) linksection(".eval") cy.Value {
    @setRuntimeSafety(debug);
    return Value.initBool(left.toF64() < right.toF64());
}

inline fn evalNotCompareNumber(left: Value, right: Value) linksection(".eval") Value {
    @setRuntimeSafety(debug);
    return Value.initBool(left.asF64() != right.toF64());
}

fn evalNotCompareOther(vm: *const VM, left: cy.Value, right: cy.Value) cy.Value {
    @setCold(true);
    @setRuntimeSafety(debug);
    if (left.isPointer()) {
        const obj = stdx.ptrAlignCast(*HeapObject, left.asPointer().?);
        if (obj.common.structId == StringS) {
            if (right.isString()) {
                const str = obj.string.ptr[0..obj.string.len];
                return Value.initBool(!std.mem.eql(u8, str, vm.valueAsString(right)));
            } else return Value.initTrue();
        } else {
            if (right.isPointer()) {
                return Value.initBool(@ptrCast(*anyopaque, obj) != right.asPointer().?);
            } else return Value.initTrue();
        }
    } else {
        switch (left.getTag()) {
            cy.TagNone => return Value.initBool(!right.isNone()),
            cy.TagBoolean => return Value.initBool(left.asBool() != right.toBool()),
            else => stdx.panic("unexpected tag"),
        }
    }
}

inline fn evalCompareNumber(left: Value, right: Value) linksection(".eval") Value {
    @setRuntimeSafety(debug);
    return Value.initBool(left.asF64() == right.toF64());
}

fn evalCompareOther(vm: *const VM, left: Value, right: Value) Value {
    @setCold(true);
    @setRuntimeSafety(debug);
    if (left.isPointer()) {
        const obj = stdx.ptrCastAlign(*HeapObject, left.asPointer().?);
        if (obj.common.structId == StringS) {
            if (right.isString()) {
                const str = obj.string.ptr[0..obj.string.len];
                return Value.initBool(std.mem.eql(u8, str, vm.valueAsString(right)));
            } else return Value.initFalse();
        } else {
            if (right.isPointer()) {
                return Value.initBool(@ptrCast(*anyopaque, obj) == right.asPointer().?);
            } else return Value.initFalse();
        }
    } else {
        switch (left.getTag()) {
            cy.TagNone => return Value.initBool(right.isNone()),
            cy.TagBoolean => return Value.initBool(left.asBool() == right.toBool()),
            cy.TagConstString => {
                if (right.isString()) {
                    const slice = left.asConstStr();
                    const str = vm.strBuf[slice.start..slice.end];
                    return Value.initBool(std.mem.eql(u8, str, vm.valueAsString(right)));
                } return Value.initFalse();
            },
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalMinus(left: cy.Value, right: cy.Value) linksection(".eval") cy.Value {
    @setRuntimeSafety(debug);
    if (left.isNumber()) {
        return Value.initF64(left.asF64() - right.toF64());
    } else {
        return @call(.{ .modifier = .never_inline }, evalMinusOther, .{left, right});
    }
}

fn evalMinusOther(left: Value, right: Value) linksection(".eval") Value {
    if (left.isPointer()) {
        return Value.initF64(left.toF64() - right.toF64());
    } else {
        switch (left.getTag()) {
            cy.TagBoolean => {
                if (left.asBool()) {
                    return Value.initF64(1 - right.toF64());
                } else {
                    return Value.initF64(-right.toF64());
                }
            },
            cy.TagNone => return Value.initF64(-right.toF64()),
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalPower(left: cy.Value, right: cy.Value) cy.Value {
    @setRuntimeSafety(debug);
    if (left.isNumber()) {
        return Value.initF64(std.math.pow(f64, left.asF64(), right.toF64()));
    } else {
        switch (left.getTag()) {
            cy.TagBoolean => {
                if (left.asBool()) {
                    return Value.initF64(1);
                } else {
                    return Value.initF64(0);
                }
            },
            cy.TagNone => return Value.initF64(0),
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalDivide(left: cy.Value, right: cy.Value) cy.Value {
    @setRuntimeSafety(debug);
    if (left.isNumber()) {
        return Value.initF64(left.asF64() / right.toF64());
    } else {
        switch (left.getTag()) {
            cy.TagBoolean => {
                if (left.asBool()) {
                    return Value.initF64(1.0 / right.toF64());
                } else {
                    return Value.initF64(0);
                }
            },
            cy.TagNone => return Value.initF64(0),
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalMod(left: cy.Value, right: cy.Value) cy.Value {
    @setRuntimeSafety(debug);
    if (left.isNumber()) {
        return Value.initF64(std.math.mod(f64, left.asF64(), right.toF64()) catch std.math.nan_f64);
    } else {
        switch (left.getTag()) {
            cy.TagBoolean => {
                if (left.asBool()) {
                    const rightf = right.toF64();
                    if (rightf > 0) {
                        return Value.initF64(1);
                    } else if (rightf == 0) {
                        return Value.initF64(std.math.nan_f64);
                    } else {
                        return Value.initF64(rightf + 1);
                    }
                } else {
                    if (right.toF64() != 0) {
                        return Value.initF64(0);
                    } else {
                        return Value.initF64(std.math.nan_f64);
                    }
                }
            },
            cy.TagNone => {
                if (right.toF64() != 0) {
                    return Value.initF64(0);
                } else {
                    return Value.initF64(std.math.nan_f64);
                }
            },
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalMultiply(left: cy.Value, right: cy.Value) cy.Value {
    @setRuntimeSafety(debug);
    if (left.isNumber()) {
        return Value.initF64(left.asF64() * right.toF64());
    } else {
        switch (left.getTag()) {
            cy.TagBoolean => {
                if (left.asBool()) {
                    return Value.initF64(right.toF64());
                } else {
                    return Value.initF64(0);
                }
            },
            cy.TagNone => return Value.initF64(0),
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalAddFallback(vm: *VM, left: cy.Value, right: cy.Value) linksection(".eval") !cy.Value {
    @setRuntimeSafety(debug);
    @setCold(true);
    if (left.isNumber()) {
        log.debug("left num", .{});
        return Value.initF64(left.asF64() + try toF64OrPanic(vm, right));
    } else {
        switch (left.getTag()) {
            cy.TagBoolean => {
                if (left.asBool()) {
                    return Value.initF64(1 + right.toF64());
                } else {
                    return Value.initF64(right.toF64());
                }
            },
            cy.TagNone => return Value.initF64(right.toF64()),
            cy.TagError => stdx.fatal(),
            cy.TagConstString => {
                // Convert into heap string.
                const slice = left.asConstStr();
                const str = vm.strBuf[slice.start..slice.end];
                return vm.allocStringConcat(str, vm.valueToTempString(right)) catch stdx.fatal();
            },
            else => stdx.panic("unexpected tag"),
        }
    }
}

inline fn evalAddNumber(left: Value, right: Value) linksection(".eval") Value {
    @setRuntimeSafety(debug);
    return Value.initF64(left.asF64() + right.asF64());
}

fn toF64OrPanic(vm: *VM, val: Value) linksection(".eval") !f64 {
    @setRuntimeSafety(debug);
    if (val.isNumber()) {
        return val.asF64();
    } else {
        return try @call(.{ .modifier = .never_inline }, convToF64OrPanic, .{vm, val});
    }
}

fn convToF64OrPanic(vm: *VM, val: Value) linksection(".eval") !f64 {
    if (val.isPointer()) {
        log.debug("right pointer", .{});
        const obj = stdx.ptrAlignCast(*cy.HeapObject, val.asPointer().?);
        if (obj.common.structId == cy.StringS) {
            const str = obj.string.ptr[0..obj.string.len];
            return std.fmt.parseFloat(f64, str) catch 0;
        } else return vm.panic("Cannot convert struct to number");
    } else {
        log.debug("right value", .{});
        switch (val.getTag()) {
            cy.TagNone => return 0,
            cy.TagBoolean => return if (val.asBool()) 1 else 0,
            else => stdx.panicFmt("unexpected tag {}", .{val.getTag()}),
        }
    }
}

fn evalNeg(val: Value) Value {
    if (val.isNumber()) {
        return Value.initF64(-val.asF64());
    } else {
        switch (val.getTag()) {
            cy.TagNone => return Value.initF64(0),
            cy.TagBoolean => {
                if (val.asBool()) {
                    return Value.initF64(-1);
                } else {
                    return Value.initF64(0);
                }
            },
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalNot(val: cy.Value) cy.Value {
    if (val.isNumber()) {
        return cy.Value.initFalse();
    } else {
        switch (val.getTag()) {
            cy.TagNone => return cy.Value.initTrue(),
            cy.TagBoolean => return Value.initBool(!val.asBool()),
            else => stdx.panic("unexpected tag"),
        }
    }
}

const NullByteId = std.math.maxInt(u8);
const NullId = std.math.maxInt(u32);

const String = packed struct {
    structId: StructId,
    rc: u32,
    ptr: [*]u8,
    len: usize,
};

const Lambda = packed struct {
    structId: StructId,
    rc: u32,
    funcPc: u32, 
    numParams: u8,
    /// Includes locals and return info. Does not include params.
    numLocals: u8,
};

const Closure = packed struct {
    structId: StructId,
    rc: u32,
    funcPc: u32, 
    numParams: u8,
    numCaptured: u8,
    /// Includes locals, captured vars, and return info. Does not include params.
    numLocals: u8,
    padding: u8,
    capturedVal0: Value,
    capturedVal1: Value,
    extra: packed union {
        capturedVal2: Value,
        ptr: ?*anyopaque,
    },
};

pub const MapInner = cy.ValueMap;
const Map = packed struct {
    structId: StructId,
    rc: u32,
    inner: packed struct {
        metadata: ?[*]u64,
        entries: ?[*]cy.ValueMapEntry,
        size: u32,
        cap: u32,
        available: u32,
        extra: u32,
    },
    // nextIterIdx: u32,
};

const List = packed struct {
    structId: StructId,
    rc: u32,
    // inner: std.ArrayListUnmanaged(Value),
    list: packed struct {
        ptr: [*]Value,
        len: usize,
        cap: usize,
    },
    nextIterIdx: u32,
};

const HeapPage = struct {
    objects: [1600]HeapObject,
};

const HeapObjectId = u32;

/// Total of 40 bytes per object. If structs are bigger they are allocated on the gpa.
pub const HeapObject = packed union {
    common: packed struct {
        structId: StructId,
    },
    freeSpan: packed struct {
        structId: StructId,
        len: u32,
        start: *HeapObject,
        next: ?*HeapObject,
    },
    retainedCommon: packed struct {
        structId: StructId,
        rc: u32,
    },
    retainedList: List,
    map: Map,
    closure: Closure,
    lambda: Lambda,
    string: String,
    smallObject: packed struct {
        structId: StructId,
        rc: u32,
        val0: Value,
        val1: Value,
        val2: Value,
        val3: Value,

        pub inline fn getValuesConstPtr(self: *const @This()) [*]const Value {
            return @ptrCast([*]const Value, &self.val0);
        }

        pub inline fn getValuesPtr(self: *@This()) [*]Value {
            return @ptrCast([*]Value, &self.val0);
        }
    },
    object: packed struct {
        structId: StructId,
        rc: u32,
        ptr: *anyopaque,
        val0: Value,
        val1: Value,
        val2: Value,
    },
};

const SymbolMapType = enum {
    oneStruct, // TODO: rename to one.
    // two,
    // ring, // Sorted mru, up to 8 syms.
    manyStructs, // TODO: rename to many.
    empty,
};

/// Keeping this small is better for function calls. TODO: Reduce size.
/// Secondary symbol data should be moved to `methodSymExtras`.
const SymbolMap = struct {
    mapT: SymbolMapType,
    inner: union {
        oneStruct: struct {
            id: StructId,
            sym: SymbolEntry,
        },
        // two: struct {
        // },
        // ring: struct {
        // },
        manyStructs: struct {
            mruStructId: StructId,
            mruSym: SymbolEntry,
        },
    },
};

const FieldSymbolMap = struct {
    mapT: SymbolMapType,
    inner: union {
        oneStruct: struct {
            id: StructId,
            fieldIdx: u16,
            isSmallObject: bool,
        },
    },
    name: []const u8,
};

test "Internals." {
    try t.eq(@sizeOf(SymbolMap), 40);
    try t.eq(@sizeOf(SymbolEntry), 16);
    try t.eq(@sizeOf(MapInner), 32);
    try t.eq(@sizeOf(HeapObject), 40);
    try t.eq(@sizeOf(HeapPage), 40 * 1600);
    try t.eq(@alignOf(HeapPage), 8);
}

const SymbolEntryType = enum {
    func,
    nativeFunc1,
    nativeFunc2,
};

pub const SymbolEntry = struct {
    entryT: SymbolEntryType,
    inner: packed union {
        nativeFunc1: std.meta.FnPtr(fn (UserVM, *anyopaque, [*]const Value, u8) Value),
        nativeFunc2: std.meta.FnPtr(fn (UserVM, *anyopaque, [*]const Value, u8) cy.ValuePair),
        func: packed struct {
            pc: u32,
            /// Includes function params, locals, and return info slot.
            numLocals: u32,
        },
    },

    pub fn initFunc(pc: u32, numLocals: u32) SymbolEntry {
        return .{
            .entryT = .func,
            .inner = .{
                .func = .{
                    .pc = pc,
                    .numLocals = numLocals,
                },
            },
        };
    }

    pub fn initNativeFunc1(func: std.meta.FnPtr(fn (UserVM, *anyopaque, [*]const Value, u8) Value)) SymbolEntry {
        return .{
            .entryT = .nativeFunc1,
            .inner = .{
                .nativeFunc1 = func,
            },
        };
    }

    fn initNativeFunc2(func: std.meta.FnPtr(fn (UserVM, *anyopaque, [*]const Value, u8) cy.ValuePair)) SymbolEntry {
        return .{
            .entryT = .nativeFunc2,
            .inner = .{
                .nativeFunc2 = func,
            },
        };
    }
};

const FuncSymbolEntryType = enum {
    nativeFunc1,
    func,
    none,
};

pub const FuncSymbolEntry = struct {
    entryT: FuncSymbolEntryType,
    inner: packed union {
        nativeFunc1: std.meta.FnPtr(fn (UserVM, [*]const Value, u8) Value),
        func: packed struct {
            pc: usize,
            /// Includes locals, and return info slot. Does not include params.
            numLocals: u32,
        },
    },

    pub fn initNativeFunc1(func: std.meta.FnPtr(fn (UserVM, [*]const Value, u8) Value)) FuncSymbolEntry {
        return .{
            .entryT = .nativeFunc1,
            .inner = .{
                .nativeFunc1 = func,
            },
        };
    }

    pub fn initFunc(pc: usize, numLocals: u32) FuncSymbolEntry {
        return .{
            .entryT = .func,
            .inner = .{
                .func = .{
                    .pc = pc,
                    .numLocals = numLocals,
                },
            },
        };
    }
};

pub const StructId = u32;

const Struct = struct {
    name: []const u8,
    numFields: u32,
};

// const StructSymbol = struct {
//     name: []const u8,
// };

const SymbolId = u32;

pub const TraceInfo = struct {
    opCounts: []OpCount,
    totalOpCounts: u32,
    numRetains: u32,
    numReleases: u32,
    numForceReleases: u32,
    numRetainCycles: u32,
    numRetainCycleRoots: u32,
};

pub const OpCount = struct {
    code: u32,
    count: u32,
};

const RcNode = struct {
    visited: bool,
    entered: bool,
};

/// Force users to use the global vm instance (to avoid deoptimization).
pub const UserVM = struct {
    dummy: u32 = 0,

    pub fn init(_: UserVM, alloc: std.mem.Allocator) !void {
        try gvm.init(alloc);
    }

    pub fn deinit(_: UserVM) void {
        gvm.deinit();
    }

    pub fn setTrace(_: UserVM, trace: *TraceInfo) void {
        gvm.trace = trace;
    }

    pub fn getStackTrace(_: UserVM) *const StackTrace {
        return gvm.getStackTrace();
    }

    pub fn getPanicMsg(_: UserVM) []const u8 {
        return gvm.panicMsg;
    }

    pub fn dumpPanicStackTrace(_: UserVM) void {
        std.debug.print("panic: {s}\n", .{gvm.panicMsg});
        const trace = gvm.getStackTrace();
        trace.dump();
    }

    pub fn dumpInfo(_: UserVM) void {
        gvm.dumpInfo();
    }

    pub fn fillUndefinedStackSpace(_: UserVM, val: Value) void {
        std.mem.set(Value, gvm.stack.buf[gvm.stack.top..], val);
    }

    pub inline fn release(_: UserVM, val: Value) void {
        gvm.release(val);
    }

    pub inline fn checkMemory(_: UserVM) !bool {
        return gvm.checkMemory();
    }

    pub inline fn compile(_: UserVM, src: []const u8) !cy.ByteCodeBuffer {
        return gvm.compile(src);
    }

    pub inline fn eval(_: UserVM, src: []const u8) !Value {
        return gvm.eval(src);
    }

    pub inline fn allocString(_: UserVM, str: []const u8) !Value {
        return gvm.allocString(str);
    }

    pub inline fn valueAsString(_: UserVM, val: Value) []const u8 {
        return gvm.valueAsString(val);
    }
};

/// To reduce the amount of code inlined in the hot loop, handle StackOverflow at the top and resume execution.
/// This is also the entry way for native code to call into the VM without deoptimizing the hot loop.
pub fn evalLoopGrowStack() linksection(".eval") error{StackOverflow, OutOfMemory, Panic, OutOfBounds, NoDebugSym, End}!void {
    @setRuntimeSafety(debug);
    while (true) {
        @call(.{ .modifier = .always_inline }, gvm.evalLoop, .{}) catch |err| {
            if (err == error.StackOverflow) {
                try gvm.stack.growTotalCapacity(gvm.alloc, gvm.stack.buf.len + 1);
                continue;
            } else if (err == error.End) {
                return;
            } else if (err == error.Panic) {
                try @call(.{ .modifier = .never_inline }, gvm.buildStackTrace, .{});
                return error.Panic;
            } else return err;
        };
        return;
    }
}

pub const EvalError = error{
    Panic,
    ParseError,
    CompileError,
    OutOfMemory,
    NoEndOp,
    End,
    OutOfBounds,
    StackOverflow,
    BadTop,
    NoDebugSym,
};

pub const StackTrace = struct {
    frames: []const StackFrame = &.{},

    fn deinit(self: *StackTrace, alloc: std.mem.Allocator) void {
        alloc.free(self.frames);
    }

    pub fn dump(self: *const StackTrace) void {
        for (self.frames) |frame| {
            std.debug.print("{s}:{}:{}\n", .{frame.name, frame.line + 1, frame.col + 1});
        }
    }
};

pub const StackFrame = struct {
    name: []const u8,
    /// Starts at 0.
    line: u32,
    /// Starts at 0.
    col: u32,
};

const MethodKey = struct {
    structId: StructId,
    methodId: SymbolId,
};