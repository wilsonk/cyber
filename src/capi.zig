const cy = @import("cyber.zig");

/// Using C headers as the single source of truth.
const c = @cImport({
    @cInclude("include/cyber.h");
});

pub const getVersion = c.csGetVersion;
pub const getFullVersion = c.csGetFullVersion;
pub const getCommit = c.csGetCommit;
pub const getBuild = c.csGetBuild;
pub const create = c.csCreate;
pub const destroy = c.csDestroy;
pub const validate = c.csValidate;
pub const eval = c.csEval;
pub const listLen = c.csListLen;
pub const listCap = c.csListCap;
pub const listAppend = c.csListAppend;
pub const listGet = c.csListGet;
pub const listSet = c.csListSet;
pub const listInsert = c.csListInsert;
pub const asFloat = c.csAsFloat;
pub const float = c.csFloat;
pub const getTypeId = c.csGetTypeId;
pub const newFunc = c.csNewFunc;
pub const newPointer = c.csNewPointer;
pub const newType = c.csNewType;
pub const symbol = c.csSymbol;
pub const asSymbolId = c.csAsSymbolId;
pub const csTrue = c.csTrue;
pub const csFalse = c.csFalse;
pub const asInteger = c.csAsInteger;
pub const integer = c.csInteger;
pub const asBool = c.csAsBool;
pub const toBool = c.csToBool;
pub const declareUntypedFunc = c.csDeclareUntypedFunc;
pub const expandTypeTemplate = c.csExpandTypeTemplate;
pub const setResolver = c.csSetResolver;
pub const setModuleLoader = c.csSetModuleLoader;
pub const setPrinter = c.csSetPrinter;
pub const setErrorPrinter = c.csSetErrorPrinter;
pub const setUserData = c.csSetUserData;
pub const getUserData = c.csGetUserData;
pub const getGlobalRC = c.csGetGlobalRC;
pub const newFirstReportSummary = c.csNewFirstReportSummary;
pub const newPanicSummary = c.csNewPanicSummary;
pub const release = c.csRelease;

pub const Str = c.CsStr;
pub fn strSlice(str: Str) []const u8 {
    return str.buf[0..str.len];
}
pub fn initStr(s: []const u8) Str {
    return .{
        .buf = s.ptr,
        .len = s.len,
    };
}

pub const ValueSlice = c.CsValueSlice;
pub fn valueSlice(self: ValueSlice) []const cy.Value {
    return @ptrCast(self.ptr[0..self.len]);
}
pub fn initValueSlice(slice: []const cy.Value) ValueSlice {
    return .{
        .ptr = @ptrCast(slice.ptr),
        .len = slice.len,
    };
}

pub const FuncFn = c.CsFuncFn;
pub const PrintFn = c.CsPrintFn;
pub const PrintErrorFn = c.CsPrintErrorFn;
pub const LogFn = c.CsLogFn;
pub const FuncInfo = c.CsFuncInfo;
pub const FuncResult = c.CsFuncResult;
pub const ModuleLoaderFn = c.CsModuleLoaderFn;
pub const ResolverFn = c.CsResolverFn;
pub const ResolverParams = c.CsResolverParams;
pub const FuncLoaderFn = c.CsFuncLoaderFn;
pub const VarLoaderFn = c.CsVarLoaderFn;
pub const TypeLoaderFn = c.CsTypeLoaderFn;
pub const ModuleOnDeinitRtFn = c.CsModuleOnDeinitRtFn;
pub const ModuleLoaderResult = c.CsModuleLoaderResult;
pub const ModuleOnTypeLoadFn = c.CsModuleOnTypeLoadFn;
pub const ModuleOnLoadFn = c.CsModuleOnLoadFn;
pub const ModuleOnDestroyFn = c.CsModuleOnDestroyFn;
pub const TypeInfo = c.CsTypeInfo;
pub const TypeResult = c.CsTypeResult;
pub const FuncType = c.CsFuncType;
pub const FuncTypeStandard = c.CS_FUNC_STANDARD;
pub const FuncTypeInline = c.CS_FUNC_INLINE;
pub const VarInfo = c.CsVarInfo;
pub const VarResult = c.CsVarResult;
pub const Value = c.CsValue;
pub const VM = c.CsVM;
pub const Sym = c.CsSym;
pub fn initSym(sym: *cy.Sym) Sym {
    return .{ .ptr = sym };
}
pub fn fromSym(sym: c.CsSym) *cy.Sym {
    return @ptrCast(@alignCast(sym.ptr));
}
pub const GCResult = c.CsGCResult;

pub const ObjectGetChildrenFn = c.CsObjectGetChildrenFn;
pub const ObjectFinalizerFn = c.CsObjectFinalizerFn;

pub const FuncEnumType = enum(u8) {
    standard = c.CS_FUNC_STANDARD,
    inlinec = c.CS_FUNC_INLINE,
};

pub const BindTypeCustom = c.CS_BIND_TYPE_CUSTOM;
pub const BindTypeDecl = c.CS_BIND_TYPE_DECL;

pub const TypeId = c.CsTypeId;
pub const TypeVoid = c.CS_TYPE_VOID;
pub const TypeBoolean = c.CS_TYPE_BOOLEAN;
pub const TypeError = c.CS_TYPE_ERROR;
pub const TypeSymbol = c.CS_TYPE_SYMBOL;
pub const TypeInteger = c.CS_TYPE_INTEGER;
pub const TypeFloat = c.CS_TYPE_FLOAT;
pub const TypeList = c.CS_TYPE_LIST;
pub const TypeListIter = c.CS_TYPE_LISTITER;
pub const TypeMap = c.CS_TYPE_MAP;
pub const TypeMapIter = c.CS_TYPE_MAPITER;
pub const TypeClosure = c.CS_TYPE_CLOSURE;
pub const TypeLambda = c.CS_TYPE_LAMBDA;
pub const TypeString = c.CS_TYPE_STRING;
pub const TypeArray = c.CS_TYPE_ARRAY;
pub const TypeFiber = c.CS_TYPE_FIBER;
pub const TypeBox = c.CS_TYPE_BOX;
pub const TypeHostFunc = c.CS_TYPE_HOST_FUNC;
pub const TypeExternFunc = c.CS_TYPE_EXTERN_FUNC;
pub const TypeTccState = c.CS_TYPE_TCCSTATE;
pub const TypePointer = c.CS_TYPE_POINTER;
pub const TypeTuple = c.CS_TYPE_TUPLE;
pub const TypeType = c.CS_TYPE_TYPE;
pub const TypeMetaType = c.CS_TYPE_METATYPE;

pub const ResultCode = c.CsResultCode;
pub const Success = c.CS_SUCCESS;
pub const ErrorCompile = c.CS_ERROR_COMPILE;
pub const ErrorPanic = c.CS_ERROR_PANIC;
pub const ErrorUnknown = c.CS_ERROR_UNKNOWN;