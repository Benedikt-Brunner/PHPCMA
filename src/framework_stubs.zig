const std = @import("std");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");

const ClassSymbol = types.ClassSymbol;
const InterfaceSymbol = types.InterfaceSymbol;
const MethodSymbol = types.MethodSymbol;
const PropertySymbol = types.PropertySymbol;
const ParameterInfo = types.ParameterInfo;
const TypeInfo = types.TypeInfo;
const SymbolTable = symbol_table.SymbolTable;

// ============================================================================
// Framework API Stub Catalog
//
// Built-in symbol table entries for commonly used framework APIs that PHPCMA
// cannot resolve from user source code (they live in vendor/).
//
// Covers: Shopware DAL, Symfony DI/HttpFoundation/Console, Doctrine DBAL/ORM
// ============================================================================

/// Register all framework stubs into the symbol table.
/// Call after user symbol collection, before inheritance resolution.
pub fn registerFrameworkStubs(allocator: std.mem.Allocator, sym_table: *SymbolTable) !void {
    // Only register stubs for classes that don't already exist in the symbol table
    // (user code or vendor stubs may have already defined them)

    // Shopware DAL
    try registerShopwareStubs(allocator, sym_table);

    // Doctrine DBAL
    try registerDoctrineDbalStubs(allocator, sym_table);

    // Doctrine ORM
    try registerDoctrineOrmStubs(allocator, sym_table);

    // Symfony DependencyInjection
    try registerSymfonyDiStubs(allocator, sym_table);

    // Symfony HttpFoundation
    try registerSymfonyHttpStubs(allocator, sym_table);

    // Symfony Console
    try registerSymfonyConsoleStubs(allocator, sym_table);

    // Symfony HttpKernel
    try registerSymfonyHttpKernelStubs(allocator, sym_table);

    // Psr
    try registerPsrStubs(allocator, sym_table);
}

// ============================================================================
// Helpers
// ============================================================================

fn t(base: []const u8) TypeInfo {
    return .{
        .kind = .simple,
        .base_type = base,
        .type_parts = &.{},
        .is_builtin = TypeInfo.isBuiltin(base),
    };
}

fn tn(base: []const u8) TypeInfo {
    return .{
        .kind = .nullable,
        .base_type = base,
        .type_parts = &.{},
        .is_builtin = TypeInfo.isBuiltin(base),
    };
}

fn param(name: []const u8, type_info: ?TypeInfo) ParameterInfo {
    return .{
        .name = name,
        .type_info = type_info,
        .has_default = false,
        .is_variadic = false,
        .is_by_reference = false,
        .is_promoted = false,
        .phpdoc_type = null,
    };
}

fn paramDefault(name: []const u8, type_info: ?TypeInfo) ParameterInfo {
    return .{
        .name = name,
        .type_info = type_info,
        .has_default = true,
        .is_variadic = false,
        .is_by_reference = false,
        .is_promoted = false,
        .phpdoc_type = null,
    };
}

fn stubMethod(
    name: []const u8,
    containing_class: []const u8,
    params: []const ParameterInfo,
    return_type: ?TypeInfo,
) MethodSymbol {
    return .{
        .name = name,
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = params,
        .return_type = return_type,
        .phpdoc_return = null,
        .start_line = 0,
        .end_line = 0,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = containing_class,
        .file_path = "<framework-stub>",
    };
}

fn stubStaticMethod(
    name: []const u8,
    containing_class: []const u8,
    params: []const ParameterInfo,
    return_type: ?TypeInfo,
) MethodSymbol {
    return .{
        .name = name,
        .visibility = .public,
        .is_static = true,
        .is_abstract = false,
        .is_final = false,
        .parameters = params,
        .return_type = return_type,
        .phpdoc_return = null,
        .start_line = 0,
        .end_line = 0,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = containing_class,
        .file_path = "<framework-stub>",
    };
}

fn stubAbstractMethod(
    name: []const u8,
    containing_class: []const u8,
    params: []const ParameterInfo,
    return_type: ?TypeInfo,
) MethodSymbol {
    return .{
        .name = name,
        .visibility = .public,
        .is_static = false,
        .is_abstract = true,
        .is_final = false,
        .parameters = params,
        .return_type = return_type,
        .phpdoc_return = null,
        .start_line = 0,
        .end_line = 0,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = containing_class,
        .file_path = "<framework-stub>",
    };
}

fn addClass(allocator: std.mem.Allocator, sym_table: *SymbolTable, fqcn: []const u8, methods: []const MethodSymbol, extends: ?[]const u8) !void {
    if (sym_table.classes.contains(fqcn)) return;

    var class = ClassSymbol.init(allocator, fqcn);
    class.file_path = "<framework-stub>";
    if (extends) |ext| class.extends = ext;

    for (methods) |method| {
        try class.addMethod(method);
    }

    try sym_table.addClass(class);
}

fn addInterface(allocator: std.mem.Allocator, sym_table: *SymbolTable, fqcn: []const u8, methods: []const MethodSymbol) !void {
    if (sym_table.interfaces.contains(fqcn)) return;

    var iface = InterfaceSymbol.init(allocator, fqcn);
    iface.file_path = "<framework-stub>";

    for (methods) |method| {
        try iface.addMethod(method);
    }

    try sym_table.addInterface(iface);
}

// ============================================================================
// Shopware DAL
// ============================================================================

fn registerShopwareStubs(allocator: std.mem.Allocator, sym_table: *SymbolTable) !void {
    const dal = "Shopware\\Core\\Framework\\DataAbstractionLayer";

    // EntityRepository
    {
        const fqcn = dal ++ "\\EntityRepository";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("search", fqcn, &.{
                param("criteria", t(dal ++ "\\Search\\Criteria")),
                param("context", t("Shopware\\Core\\Framework\\Context")),
            }, t(dal ++ "\\Search\\EntitySearchResult")),
            stubMethod("searchIds", fqcn, &.{
                param("criteria", t(dal ++ "\\Search\\Criteria")),
                param("context", t("Shopware\\Core\\Framework\\Context")),
            }, t(dal ++ "\\Search\\IdSearchResult")),
            stubMethod("aggregate", fqcn, &.{
                param("criteria", t(dal ++ "\\Search\\Criteria")),
                param("context", t("Shopware\\Core\\Framework\\Context")),
            }, t(dal ++ "\\Search\\AggregationResult\\AggregationResultCollection")),
            stubMethod("create", fqcn, &.{
                param("data", t("array")),
                param("context", t("Shopware\\Core\\Framework\\Context")),
            }, t(dal ++ "\\Event\\EntityWrittenContainerEvent")),
            stubMethod("update", fqcn, &.{
                param("data", t("array")),
                param("context", t("Shopware\\Core\\Framework\\Context")),
            }, t(dal ++ "\\Event\\EntityWrittenContainerEvent")),
            stubMethod("upsert", fqcn, &.{
                param("data", t("array")),
                param("context", t("Shopware\\Core\\Framework\\Context")),
            }, t(dal ++ "\\Event\\EntityWrittenContainerEvent")),
            stubMethod("delete", fqcn, &.{
                param("ids", t("array")),
                param("context", t("Shopware\\Core\\Framework\\Context")),
            }, t(dal ++ "\\Event\\EntityWrittenContainerEvent")),
            stubMethod("clone", fqcn, &.{
                param("id", t("string")),
                param("context", t("Shopware\\Core\\Framework\\Context")),
            }, t(dal ++ "\\Event\\EntityWrittenContainerEvent")),
        }, null);
    }

    // EntityCollection
    {
        const fqcn = dal ++ "\\EntityCollection";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("getEntities", fqcn, &.{}, t(dal ++ "\\EntityCollection")),
            stubMethod("first", fqcn, &.{}, tn(dal ++ "\\Entity")),
            stubMethod("last", fqcn, &.{}, tn(dal ++ "\\Entity")),
            stubMethod("count", fqcn, &.{}, t("int")),
            stubMethod("getIds", fqcn, &.{}, t("array")),
            stubMethod("filterByProperty", fqcn, &.{
                param("property", t("string")),
                param("value", null),
            }, t(dal ++ "\\EntityCollection")),
            stubMethod("getElements", fqcn, &.{}, t("array")),
            stubMethod("get", fqcn, &.{param("id", t("string"))}, tn(dal ++ "\\Entity")),
            stubMethod("has", fqcn, &.{param("id", t("string"))}, t("bool")),
            stubMethod("map", fqcn, &.{param("callback", t("callable"))}, t("array")),
            stubMethod("fmap", fqcn, &.{param("callback", t("callable"))}, t(dal ++ "\\EntityCollection")),
            stubMethod("sort", fqcn, &.{param("callback", t("callable"))}, t("void")),
            stubMethod("add", fqcn, &.{param("entity", t(dal ++ "\\Entity"))}, t("void")),
            stubMethod("remove", fqcn, &.{param("id", t("string"))}, t("void")),
        }, null);
    }

    // Entity
    {
        const fqcn = dal ++ "\\Entity";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("getId", fqcn, &.{}, t("string")),
            stubMethod("getUniqueIdentifier", fqcn, &.{}, t("string")),
            stubMethod("get", fqcn, &.{param("property", t("string"))}, null),
            stubMethod("has", fqcn, &.{param("property", t("string"))}, t("bool")),
            stubMethod("getTranslation", fqcn, &.{param("property", t("string"))}, null),
            stubMethod("getTranslated", fqcn, &.{}, t("array")),
            stubMethod("getCreatedAt", fqcn, &.{}, tn("DateTimeImmutable")),
            stubMethod("getUpdatedAt", fqcn, &.{}, tn("DateTimeImmutable")),
            stubMethod("jsonSerialize", fqcn, &.{}, t("array")),
            stubMethod("getExtension", fqcn, &.{param("name", t("string"))}, tn(dal ++ "\\Struct")),
            stubMethod("addExtension", fqcn, &.{
                param("name", t("string")),
                param("extension", t(dal ++ "\\Struct")),
            }, t("void")),
            stubMethod("hasExtension", fqcn, &.{param("name", t("string"))}, t("bool")),
        }, null);
    }

    // Search\\Criteria
    {
        const fqcn = dal ++ "\\Search\\Criteria";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("addFilter", fqcn, &.{
                param("filter", t(dal ++ "\\Search\\Filter\\Filter")),
            }, t(dal ++ "\\Search\\Criteria")),
            stubMethod("addSorting", fqcn, &.{
                param("sorting", t(dal ++ "\\Search\\Sorting\\FieldSorting")),
            }, t(dal ++ "\\Search\\Criteria")),
            stubMethod("addAssociation", fqcn, &.{
                param("association", t("string")),
            }, t(dal ++ "\\Search\\Criteria")),
            stubMethod("addAggregation", fqcn, &.{
                param("aggregation", t(dal ++ "\\Search\\Aggregation\\Aggregation")),
            }, t(dal ++ "\\Search\\Criteria")),
            stubMethod("setLimit", fqcn, &.{param("limit", t("int"))}, t(dal ++ "\\Search\\Criteria")),
            stubMethod("setOffset", fqcn, &.{param("offset", t("int"))}, t(dal ++ "\\Search\\Criteria")),
            stubMethod("setTotalCountMode", fqcn, &.{param("mode", t("int"))}, t(dal ++ "\\Search\\Criteria")),
            stubMethod("getLimit", fqcn, &.{}, tn("int")),
            stubMethod("getOffset", fqcn, &.{}, tn("int")),
            stubMethod("setTitle", fqcn, &.{param("title", t("string"))}, t(dal ++ "\\Search\\Criteria")),
            stubMethod("getTitle", fqcn, &.{}, tn("string")),
            stubMethod("setIds", fqcn, &.{param("ids", t("array"))}, t(dal ++ "\\Search\\Criteria")),
            stubMethod("getIds", fqcn, &.{}, t("array")),
            stubMethod("getFilters", fqcn, &.{}, t("array")),
            stubMethod("getPostFilters", fqcn, &.{}, t("array")),
            stubMethod("getSorting", fqcn, &.{}, t("array")),
            stubMethod("getAssociations", fqcn, &.{}, t("array")),
            stubMethod("setTerm", fqcn, &.{param("term", tn("string"))}, t(dal ++ "\\Search\\Criteria")),
            stubMethod("getTerm", fqcn, &.{}, tn("string")),
        }, null);
    }

    // Search\\EntitySearchResult
    {
        const fqcn = dal ++ "\\Search\\EntitySearchResult";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("getEntities", fqcn, &.{}, t(dal ++ "\\EntityCollection")),
            stubMethod("first", fqcn, &.{}, tn(dal ++ "\\Entity")),
            stubMethod("last", fqcn, &.{}, tn(dal ++ "\\Entity")),
            stubMethod("count", fqcn, &.{}, t("int")),
            stubMethod("getTotal", fqcn, &.{}, t("int")),
            stubMethod("getAggregations", fqcn, &.{}, t(dal ++ "\\Search\\AggregationResult\\AggregationResultCollection")),
            stubMethod("getCriteria", fqcn, &.{}, t(dal ++ "\\Search\\Criteria")),
            stubMethod("getContext", fqcn, &.{}, t("Shopware\\Core\\Framework\\Context")),
            stubMethod("getElements", fqcn, &.{}, t("array")),
            stubMethod("getIds", fqcn, &.{}, t("array")),
            stubMethod("get", fqcn, &.{param("id", t("string"))}, tn(dal ++ "\\Entity")),
            stubMethod("has", fqcn, &.{param("id", t("string"))}, t("bool")),
        }, dal ++ "\\EntityCollection");
    }

    // Context
    {
        const fqcn = "Shopware\\Core\\Framework\\Context";
        try addClass(allocator, sym_table, fqcn, &.{
            stubStaticMethod("createDefaultContext", fqcn, &.{}, t(fqcn)),
            stubMethod("getScope", fqcn, &.{}, t("string")),
            stubMethod("setScope", fqcn, &.{param("scope", t("string"))}, t("void")),
            stubMethod("getLanguageId", fqcn, &.{}, t("string")),
            stubMethod("getVersionId", fqcn, &.{}, t("string")),
            stubMethod("getCurrencyId", fqcn, &.{}, t("string")),
            stubMethod("getCurrencyFactor", fqcn, &.{}, t("float")),
            stubMethod("getRounding", fqcn, &.{}, t("Shopware\\Core\\Framework\\DataAbstractionLayer\\Pricing\\CashRoundingConfig")),
            stubMethod("getTaxState", fqcn, &.{}, t("string")),
            stubMethod("getSource", fqcn, &.{}, t("Shopware\\Core\\Framework\\Api\\Context\\ContextSource")),
        }, null);
    }

    // SalesChannelContext
    {
        const fqcn = "Shopware\\Core\\System\\SalesChannel\\SalesChannelContext";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("getContext", fqcn, &.{}, t("Shopware\\Core\\Framework\\Context")),
            stubMethod("getSalesChannel", fqcn, &.{}, t("Shopware\\Core\\System\\SalesChannel\\SalesChannelEntity")),
            stubMethod("getSalesChannelId", fqcn, &.{}, t("string")),
            stubMethod("getCurrency", fqcn, &.{}, t("Shopware\\Core\\System\\Currency\\CurrencyEntity")),
            stubMethod("getCustomer", fqcn, &.{}, tn("Shopware\\Core\\Checkout\\Customer\\CustomerEntity")),
            stubMethod("getCustomerId", fqcn, &.{}, tn("string")),
            stubMethod("getPaymentMethod", fqcn, &.{}, t("Shopware\\Core\\Checkout\\Payment\\PaymentMethodEntity")),
            stubMethod("getShippingMethod", fqcn, &.{}, t("Shopware\\Core\\Checkout\\Shipping\\ShippingMethodEntity")),
            stubMethod("getTaxState", fqcn, &.{}, t("string")),
            stubMethod("getToken", fqcn, &.{}, t("string")),
            stubMethod("getLanguageId", fqcn, &.{}, t("string")),
        }, null);
    }
}

// ============================================================================
// Doctrine DBAL
// ============================================================================

fn registerDoctrineDbalStubs(allocator: std.mem.Allocator, sym_table: *SymbolTable) !void {
    const dbal = "Doctrine\\DBAL";

    // Connection
    {
        const fqcn = dbal ++ "\\Connection";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("executeQuery", fqcn, &.{
                param("sql", t("string")),
                paramDefault("params", t("array")),
                paramDefault("types", t("array")),
            }, t(dbal ++ "\\Result")),
            stubMethod("executeStatement", fqcn, &.{
                param("sql", t("string")),
                paramDefault("params", t("array")),
                paramDefault("types", t("array")),
            }, t("int")),
            stubMethod("prepare", fqcn, &.{
                param("sql", t("string")),
            }, t(dbal ++ "\\Statement")),
            stubMethod("fetchAllAssociative", fqcn, &.{
                param("query", t("string")),
                paramDefault("params", t("array")),
                paramDefault("types", t("array")),
            }, t("array")),
            stubMethod("fetchAssociative", fqcn, &.{
                param("query", t("string")),
                paramDefault("params", t("array")),
                paramDefault("types", t("array")),
            }, null),
            stubMethod("fetchOne", fqcn, &.{
                param("query", t("string")),
                paramDefault("params", t("array")),
                paramDefault("types", t("array")),
            }, null),
            stubMethod("fetchAllKeyValue", fqcn, &.{
                param("query", t("string")),
                paramDefault("params", t("array")),
                paramDefault("types", t("array")),
            }, t("array")),
            stubMethod("fetchAllNumeric", fqcn, &.{
                param("query", t("string")),
                paramDefault("params", t("array")),
                paramDefault("types", t("array")),
            }, t("array")),
            stubMethod("fetchFirstColumn", fqcn, &.{
                param("query", t("string")),
                paramDefault("params", t("array")),
                paramDefault("types", t("array")),
            }, t("array")),
            stubMethod("insert", fqcn, &.{
                param("table", t("string")),
                param("data", t("array")),
                paramDefault("types", t("array")),
            }, t("int")),
            stubMethod("update", fqcn, &.{
                param("table", t("string")),
                param("data", t("array")),
                param("criteria", t("array")),
                paramDefault("types", t("array")),
            }, t("int")),
            stubMethod("delete", fqcn, &.{
                param("table", t("string")),
                param("criteria", t("array")),
                paramDefault("types", t("array")),
            }, t("int")),
            stubMethod("createQueryBuilder", fqcn, &.{}, t(dbal ++ "\\Query\\QueryBuilder")),
            stubMethod("beginTransaction", fqcn, &.{}, t("void")),
            stubMethod("commit", fqcn, &.{}, t("void")),
            stubMethod("rollBack", fqcn, &.{}, t("void")),
            stubMethod("transactional", fqcn, &.{param("func", t("callable"))}, null),
            stubMethod("lastInsertId", fqcn, &.{}, t("string")),
            stubMethod("quoteIdentifier", fqcn, &.{param("str", t("string"))}, t("string")),
            stubMethod("quote", fqcn, &.{param("value", t("string"))}, t("string")),
            stubMethod("getDatabase", fqcn, &.{}, tn("string")),
        }, null);
    }

    // Result
    {
        const fqcn = dbal ++ "\\Result";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("fetchAssociative", fqcn, &.{}, null),
            stubMethod("fetchNumeric", fqcn, &.{}, null),
            stubMethod("fetchOne", fqcn, &.{}, null),
            stubMethod("fetchAllAssociative", fqcn, &.{}, t("array")),
            stubMethod("fetchAllNumeric", fqcn, &.{}, t("array")),
            stubMethod("fetchAllKeyValue", fqcn, &.{}, t("array")),
            stubMethod("fetchFirstColumn", fqcn, &.{}, t("array")),
            stubMethod("rowCount", fqcn, &.{}, t("int")),
            stubMethod("columnCount", fqcn, &.{}, t("int")),
            stubMethod("free", fqcn, &.{}, t("void")),
        }, null);
    }

    // Statement
    {
        const fqcn = dbal ++ "\\Statement";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("bindValue", fqcn, &.{
                param("param", null),
                param("value", null),
                paramDefault("type", t("int")),
            }, t("void")),
            stubMethod("bindParam", fqcn, &.{
                param("param", null),
                param("variable", null),
                paramDefault("type", t("int")),
                paramDefault("length", tn("int")),
            }, t("void")),
            stubMethod("execute", fqcn, &.{
                paramDefault("params", tn("array")),
            }, t(dbal ++ "\\Result")),
        }, null);
    }

    // Query\\QueryBuilder
    {
        const fqcn = dbal ++ "\\Query\\QueryBuilder";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("select", fqcn, &.{param("select", t("string"))}, t(fqcn)),
            stubMethod("addSelect", fqcn, &.{param("select", t("string"))}, t(fqcn)),
            stubMethod("from", fqcn, &.{
                param("table", t("string")),
                paramDefault("alias", tn("string")),
            }, t(fqcn)),
            stubMethod("join", fqcn, &.{
                param("fromAlias", t("string")),
                param("join", t("string")),
                param("alias", t("string")),
                paramDefault("condition", tn("string")),
            }, t(fqcn)),
            stubMethod("innerJoin", fqcn, &.{
                param("fromAlias", t("string")),
                param("join", t("string")),
                param("alias", t("string")),
                paramDefault("condition", tn("string")),
            }, t(fqcn)),
            stubMethod("leftJoin", fqcn, &.{
                param("fromAlias", t("string")),
                param("join", t("string")),
                param("alias", t("string")),
                paramDefault("condition", tn("string")),
            }, t(fqcn)),
            stubMethod("where", fqcn, &.{param("predicates", t("string"))}, t(fqcn)),
            stubMethod("andWhere", fqcn, &.{param("where", t("string"))}, t(fqcn)),
            stubMethod("orWhere", fqcn, &.{param("where", t("string"))}, t(fqcn)),
            stubMethod("groupBy", fqcn, &.{param("groupBy", t("string"))}, t(fqcn)),
            stubMethod("having", fqcn, &.{param("having", t("string"))}, t(fqcn)),
            stubMethod("orderBy", fqcn, &.{
                param("sort", t("string")),
                paramDefault("order", tn("string")),
            }, t(fqcn)),
            stubMethod("addOrderBy", fqcn, &.{
                param("sort", t("string")),
                paramDefault("order", tn("string")),
            }, t(fqcn)),
            stubMethod("setParameter", fqcn, &.{
                param("key", null),
                param("value", null),
                paramDefault("type", tn("string")),
            }, t(fqcn)),
            stubMethod("setMaxResults", fqcn, &.{param("maxResults", tn("int"))}, t(fqcn)),
            stubMethod("setFirstResult", fqcn, &.{param("firstResult", t("int"))}, t(fqcn)),
            stubMethod("executeQuery", fqcn, &.{}, t(dbal ++ "\\Result")),
            stubMethod("executeStatement", fqcn, &.{}, t("int")),
            stubMethod("getSQL", fqcn, &.{}, t("string")),
            stubMethod("getParameters", fqcn, &.{}, t("array")),
            stubMethod("createNamedParameter", fqcn, &.{
                param("value", null),
                paramDefault("type", t("int")),
                paramDefault("placeHolder", tn("string")),
            }, t("string")),
            stubMethod("createPositionalParameter", fqcn, &.{
                param("value", null),
                paramDefault("type", t("int")),
            }, t("string")),
            stubMethod("delete", fqcn, &.{
                param("table", t("string")),
                paramDefault("alias", tn("string")),
            }, t(fqcn)),
            stubMethod("insert", fqcn, &.{param("table", t("string"))}, t(fqcn)),
            stubMethod("update", fqcn, &.{
                param("table", t("string")),
                paramDefault("alias", tn("string")),
            }, t(fqcn)),
            stubMethod("set", fqcn, &.{
                param("key", t("string")),
                param("value", t("string")),
            }, t(fqcn)),
            stubMethod("setValue", fqcn, &.{
                param("column", t("string")),
                param("value", t("string")),
            }, t(fqcn)),
            stubMethod("values", fqcn, &.{param("values", t("array"))}, t(fqcn)),
        }, null);
    }
}

// ============================================================================
// Doctrine ORM
// ============================================================================

fn registerDoctrineOrmStubs(allocator: std.mem.Allocator, sym_table: *SymbolTable) !void {
    const orm = "Doctrine\\ORM";

    // EntityManagerInterface
    {
        const fqcn = orm ++ "\\EntityManagerInterface";
        try addInterface(allocator, sym_table, fqcn, &.{
            stubAbstractMethod("find", fqcn, &.{
                param("className", t("string")),
                param("id", null),
            }, tn("object")),
            stubAbstractMethod("persist", fqcn, &.{param("object", t("object"))}, t("void")),
            stubAbstractMethod("remove", fqcn, &.{param("object", t("object"))}, t("void")),
            stubAbstractMethod("flush", fqcn, &.{}, t("void")),
            stubAbstractMethod("getRepository", fqcn, &.{param("className", t("string"))}, t(orm ++ "\\EntityRepository")),
            stubAbstractMethod("getReference", fqcn, &.{
                param("className", t("string")),
                param("id", null),
            }, tn("object")),
            stubAbstractMethod("clear", fqcn, &.{}, t("void")),
            stubAbstractMethod("detach", fqcn, &.{param("object", t("object"))}, t("void")),
            stubAbstractMethod("refresh", fqcn, &.{param("object", t("object"))}, t("void")),
            stubAbstractMethod("contains", fqcn, &.{param("object", t("object"))}, t("bool")),
            stubAbstractMethod("createQueryBuilder", fqcn, &.{}, t(orm ++ "\\QueryBuilder")),
            stubAbstractMethod("createQuery", fqcn, &.{paramDefault("dql", tn("string"))}, t(orm ++ "\\Query")),
            stubAbstractMethod("getConnection", fqcn, &.{}, t("Doctrine\\DBAL\\Connection")),
            stubAbstractMethod("beginTransaction", fqcn, &.{}, t("void")),
            stubAbstractMethod("commit", fqcn, &.{}, t("void")),
            stubAbstractMethod("rollback", fqcn, &.{}, t("void")),
        });
    }

    // EntityManager (implements EntityManagerInterface)
    {
        const fqcn = orm ++ "\\EntityManager";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("find", fqcn, &.{
                param("className", t("string")),
                param("id", null),
            }, tn("object")),
            stubMethod("persist", fqcn, &.{param("object", t("object"))}, t("void")),
            stubMethod("remove", fqcn, &.{param("object", t("object"))}, t("void")),
            stubMethod("flush", fqcn, &.{}, t("void")),
            stubMethod("getRepository", fqcn, &.{param("className", t("string"))}, t(orm ++ "\\EntityRepository")),
            stubMethod("getReference", fqcn, &.{
                param("className", t("string")),
                param("id", null),
            }, tn("object")),
            stubMethod("clear", fqcn, &.{}, t("void")),
            stubMethod("detach", fqcn, &.{param("object", t("object"))}, t("void")),
            stubMethod("refresh", fqcn, &.{param("object", t("object"))}, t("void")),
            stubMethod("contains", fqcn, &.{param("object", t("object"))}, t("bool")),
            stubMethod("createQueryBuilder", fqcn, &.{}, t(orm ++ "\\QueryBuilder")),
            stubMethod("createQuery", fqcn, &.{paramDefault("dql", tn("string"))}, t(orm ++ "\\Query")),
            stubMethod("getConnection", fqcn, &.{}, t("Doctrine\\DBAL\\Connection")),
            stubMethod("beginTransaction", fqcn, &.{}, t("void")),
            stubMethod("commit", fqcn, &.{}, t("void")),
            stubMethod("rollback", fqcn, &.{}, t("void")),
        }, null);
    }

    // EntityRepository (Doctrine ORM)
    {
        const fqcn = orm ++ "\\EntityRepository";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("find", fqcn, &.{param("id", null)}, tn("object")),
            stubMethod("findAll", fqcn, &.{}, t("array")),
            stubMethod("findBy", fqcn, &.{
                param("criteria", t("array")),
                paramDefault("orderBy", tn("array")),
                paramDefault("limit", tn("int")),
                paramDefault("offset", tn("int")),
            }, t("array")),
            stubMethod("findOneBy", fqcn, &.{param("criteria", t("array"))}, tn("object")),
            stubMethod("getClassName", fqcn, &.{}, t("string")),
            stubMethod("count", fqcn, &.{param("criteria", t("array"))}, t("int")),
            stubMethod("createQueryBuilder", fqcn, &.{
                paramDefault("alias", t("string")),
                paramDefault("indexBy", tn("string")),
            }, t(orm ++ "\\QueryBuilder")),
            stubMethod("matching", fqcn, &.{
                param("criteria", t("Doctrine\\Common\\Collections\\Criteria")),
            }, t("Doctrine\\Common\\Collections\\Collection")),
        }, null);
    }

    // QueryBuilder (Doctrine ORM)
    {
        const fqcn = orm ++ "\\QueryBuilder";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("select", fqcn, &.{param("select", null)}, t(fqcn)),
            stubMethod("addSelect", fqcn, &.{param("select", null)}, t(fqcn)),
            stubMethod("from", fqcn, &.{
                param("from", t("string")),
                paramDefault("alias", tn("string")),
                paramDefault("indexBy", tn("string")),
            }, t(fqcn)),
            stubMethod("join", fqcn, &.{
                param("join", t("string")),
                param("alias", t("string")),
                paramDefault("conditionType", tn("string")),
                paramDefault("condition", tn("string")),
                paramDefault("indexBy", tn("string")),
            }, t(fqcn)),
            stubMethod("innerJoin", fqcn, &.{
                param("join", t("string")),
                param("alias", t("string")),
                paramDefault("conditionType", tn("string")),
                paramDefault("condition", tn("string")),
                paramDefault("indexBy", tn("string")),
            }, t(fqcn)),
            stubMethod("leftJoin", fqcn, &.{
                param("join", t("string")),
                param("alias", t("string")),
                paramDefault("conditionType", tn("string")),
                paramDefault("condition", tn("string")),
                paramDefault("indexBy", tn("string")),
            }, t(fqcn)),
            stubMethod("where", fqcn, &.{param("predicates", null)}, t(fqcn)),
            stubMethod("andWhere", fqcn, &.{param("where", null)}, t(fqcn)),
            stubMethod("orWhere", fqcn, &.{param("where", null)}, t(fqcn)),
            stubMethod("groupBy", fqcn, &.{param("groupBy", null)}, t(fqcn)),
            stubMethod("having", fqcn, &.{param("having", null)}, t(fqcn)),
            stubMethod("orderBy", fqcn, &.{
                param("sort", null),
                paramDefault("order", tn("string")),
            }, t(fqcn)),
            stubMethod("addOrderBy", fqcn, &.{
                param("sort", null),
                paramDefault("order", tn("string")),
            }, t(fqcn)),
            stubMethod("setParameter", fqcn, &.{
                param("key", null),
                param("value", null),
                paramDefault("type", tn("string")),
            }, t(fqcn)),
            stubMethod("setMaxResults", fqcn, &.{param("maxResults", tn("int"))}, t(fqcn)),
            stubMethod("setFirstResult", fqcn, &.{param("firstResult", t("int"))}, t(fqcn)),
            stubMethod("getQuery", fqcn, &.{}, t(orm ++ "\\Query")),
            stubMethod("getDQL", fqcn, &.{}, t("string")),
            stubMethod("expr", fqcn, &.{}, t(orm ++ "\\Query\\Expr")),
        }, null);
    }

    // Query
    {
        const fqcn = orm ++ "\\Query";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("getResult", fqcn, &.{paramDefault("hydrationMode", t("int"))}, t("array")),
            stubMethod("getArrayResult", fqcn, &.{}, t("array")),
            stubMethod("getScalarResult", fqcn, &.{}, t("array")),
            stubMethod("getSingleResult", fqcn, &.{paramDefault("hydrationMode", t("int"))}, null),
            stubMethod("getSingleScalarResult", fqcn, &.{}, null),
            stubMethod("getOneOrNullResult", fqcn, &.{paramDefault("hydrationMode", t("int"))}, null),
            stubMethod("execute", fqcn, &.{}, null),
            stubMethod("setParameter", fqcn, &.{
                param("key", null),
                param("value", null),
                paramDefault("type", tn("string")),
            }, t(fqcn)),
            stubMethod("setParameters", fqcn, &.{param("parameters", null)}, t(fqcn)),
            stubMethod("setMaxResults", fqcn, &.{param("maxResults", tn("int"))}, t(fqcn)),
            stubMethod("setFirstResult", fqcn, &.{param("firstResult", tn("int"))}, t(fqcn)),
            stubMethod("setDQL", fqcn, &.{param("dqlQuery", t("string"))}, t(fqcn)),
            stubMethod("getDQL", fqcn, &.{}, tn("string")),
            stubMethod("getSQL", fqcn, &.{}, t("string")),
        }, null);
    }
}

// ============================================================================
// Symfony DependencyInjection
// ============================================================================

fn registerSymfonyDiStubs(allocator: std.mem.Allocator, sym_table: *SymbolTable) !void {
    const di = "Symfony\\Component\\DependencyInjection";

    // ContainerInterface
    {
        const fqcn = di ++ "\\ContainerInterface";
        try addInterface(allocator, sym_table, fqcn, &.{
            stubAbstractMethod("get", fqcn, &.{
                param("id", t("string")),
                paramDefault("invalidBehavior", t("int")),
            }, tn("object")),
            stubAbstractMethod("has", fqcn, &.{param("id", t("string"))}, t("bool")),
            stubAbstractMethod("initialized", fqcn, &.{param("id", t("string"))}, t("bool")),
            stubAbstractMethod("getParameter", fqcn, &.{param("name", t("string"))}, null),
            stubAbstractMethod("hasParameter", fqcn, &.{param("name", t("string"))}, t("bool")),
            stubAbstractMethod("setParameter", fqcn, &.{
                param("name", t("string")),
                param("value", null),
            }, t("void")),
        });
    }

    // ContainerBuilder
    {
        const fqcn = di ++ "\\ContainerBuilder";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("get", fqcn, &.{
                param("id", t("string")),
                paramDefault("invalidBehavior", t("int")),
            }, tn("object")),
            stubMethod("has", fqcn, &.{param("id", t("string"))}, t("bool")),
            stubMethod("register", fqcn, &.{
                param("id", t("string")),
                paramDefault("class", tn("string")),
            }, t(di ++ "\\Definition")),
            stubMethod("setDefinition", fqcn, &.{
                param("id", t("string")),
                param("definition", t(di ++ "\\Definition")),
            }, t(di ++ "\\Definition")),
            stubMethod("getDefinition", fqcn, &.{param("id", t("string"))}, t(di ++ "\\Definition")),
            stubMethod("hasDefinition", fqcn, &.{param("id", t("string"))}, t("bool")),
            stubMethod("findTaggedServiceIds", fqcn, &.{
                param("name", t("string")),
                paramDefault("throwOnAbstract", t("bool")),
            }, t("array")),
            stubMethod("setAlias", fqcn, &.{
                param("alias", t("string")),
                param("id", null),
            }, t(di ++ "\\Alias")),
            stubMethod("setParameter", fqcn, &.{
                param("name", t("string")),
                param("value", null),
            }, t("void")),
            stubMethod("getParameter", fqcn, &.{param("name", t("string"))}, null),
            stubMethod("hasParameter", fqcn, &.{param("name", t("string"))}, t("bool")),
            stubMethod("getParameterBag", fqcn, &.{}, t(di ++ "\\ParameterBag\\ParameterBagInterface")),
            stubMethod("compile", fqcn, &.{}, t("void")),
        }, null);
    }

    // Definition
    {
        const fqcn = di ++ "\\Definition";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("setClass", fqcn, &.{param("class", t("string"))}, t(fqcn)),
            stubMethod("getClass", fqcn, &.{}, tn("string")),
            stubMethod("setArguments", fqcn, &.{param("arguments", t("array"))}, t(fqcn)),
            stubMethod("addArgument", fqcn, &.{param("argument", null)}, t(fqcn)),
            stubMethod("addMethodCall", fqcn, &.{
                param("method", t("string")),
                paramDefault("arguments", t("array")),
            }, t(fqcn)),
            stubMethod("addTag", fqcn, &.{
                param("name", t("string")),
                paramDefault("attributes", t("array")),
            }, t(fqcn)),
            stubMethod("setPublic", fqcn, &.{param("boolean", t("bool"))}, t(fqcn)),
            stubMethod("setLazy", fqcn, &.{param("lazy", t("bool"))}, t(fqcn)),
            stubMethod("setAutowired", fqcn, &.{param("autowired", t("bool"))}, t(fqcn)),
            stubMethod("setAutoconfigured", fqcn, &.{param("autoconfigured", t("bool"))}, t(fqcn)),
            stubMethod("setFactory", fqcn, &.{param("factory", null)}, t(fqcn)),
            stubMethod("setDecoratedService", fqcn, &.{
                param("id", tn("string")),
                paramDefault("renamedId", tn("string")),
                paramDefault("priority", t("int")),
            }, t(fqcn)),
        }, null);
    }
}

// ============================================================================
// Symfony HttpFoundation
// ============================================================================

fn registerSymfonyHttpStubs(allocator: std.mem.Allocator, sym_table: *SymbolTable) !void {
    const http = "Symfony\\Component\\HttpFoundation";

    // Request
    {
        const fqcn = http ++ "\\Request";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("get", fqcn, &.{
                param("key", t("string")),
                paramDefault("default", null),
            }, null),
            stubMethod("getContent", fqcn, &.{paramDefault("asResource", t("bool"))}, null),
            stubMethod("getMethod", fqcn, &.{}, t("string")),
            stubMethod("getUri", fqcn, &.{}, t("string")),
            stubMethod("getPathInfo", fqcn, &.{}, t("string")),
            stubMethod("getRequestUri", fqcn, &.{}, t("string")),
            stubMethod("getHost", fqcn, &.{}, t("string")),
            stubMethod("getScheme", fqcn, &.{}, t("string")),
            stubMethod("getClientIp", fqcn, &.{}, tn("string")),
            stubMethod("getLocale", fqcn, &.{}, t("string")),
            stubMethod("getSession", fqcn, &.{}, t(http ++ "\\Session\\SessionInterface")),
            stubMethod("hasSession", fqcn, &.{}, t("bool")),
            stubMethod("isXmlHttpRequest", fqcn, &.{}, t("bool")),
            stubMethod("isMethod", fqcn, &.{param("method", t("string"))}, t("bool")),
            stubMethod("getPreferredLanguage", fqcn, &.{paramDefault("locales", tn("array"))}, tn("string")),
            stubMethod("isSecure", fqcn, &.{}, t("bool")),
            stubStaticMethod("createFromGlobals", fqcn, &.{}, t(fqcn)),
            stubStaticMethod("create", fqcn, &.{
                param("uri", t("string")),
                paramDefault("method", t("string")),
                paramDefault("parameters", t("array")),
            }, t(fqcn)),
        }, null);
    }

    // Response
    {
        const fqcn = http ++ "\\Response";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("getContent", fqcn, &.{}, null),
            stubMethod("setContent", fqcn, &.{param("content", tn("string"))}, t(fqcn)),
            stubMethod("getStatusCode", fqcn, &.{}, t("int")),
            stubMethod("setStatusCode", fqcn, &.{
                param("code", t("int")),
                paramDefault("text", tn("string")),
            }, t(fqcn)),
            stubMethod("headers", fqcn, &.{}, t(http ++ "\\ResponseHeaderBag")),
            stubMethod("send", fqcn, &.{}, t(fqcn)),
            stubMethod("sendHeaders", fqcn, &.{}, t(fqcn)),
            stubMethod("sendContent", fqcn, &.{}, t(fqcn)),
            stubMethod("setCharset", fqcn, &.{param("charset", t("string"))}, t(fqcn)),
            stubMethod("isSuccessful", fqcn, &.{}, t("bool")),
            stubMethod("isRedirection", fqcn, &.{}, t("bool")),
            stubMethod("isClientError", fqcn, &.{}, t("bool")),
            stubMethod("isServerError", fqcn, &.{}, t("bool")),
        }, null);
    }

    // JsonResponse
    {
        const fqcn = http ++ "\\JsonResponse";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("setData", fqcn, &.{paramDefault("data", null)}, t(fqcn)),
            stubMethod("setEncodingOptions", fqcn, &.{param("encodingOptions", t("int"))}, t(fqcn)),
            stubMethod("getEncodingOptions", fqcn, &.{}, t("int")),
            stubStaticMethod("fromJsonString", fqcn, &.{
                param("data", t("string")),
                paramDefault("status", t("int")),
                paramDefault("headers", t("array")),
            }, t(fqcn)),
        }, http ++ "\\Response");
    }

    // RedirectResponse
    {
        const fqcn = http ++ "\\RedirectResponse";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("getTargetUrl", fqcn, &.{}, t("string")),
        }, http ++ "\\Response");
    }

    // ParameterBag
    {
        const fqcn = http ++ "\\ParameterBag";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("get", fqcn, &.{
                param("key", t("string")),
                paramDefault("default", null),
            }, null),
            stubMethod("set", fqcn, &.{
                param("key", t("string")),
                param("value", null),
            }, t("void")),
            stubMethod("has", fqcn, &.{param("key", t("string"))}, t("bool")),
            stubMethod("all", fqcn, &.{}, t("array")),
            stubMethod("keys", fqcn, &.{}, t("array")),
            stubMethod("count", fqcn, &.{}, t("int")),
            stubMethod("getInt", fqcn, &.{
                param("key", t("string")),
                paramDefault("default", t("int")),
            }, t("int")),
            stubMethod("getBoolean", fqcn, &.{
                param("key", t("string")),
                paramDefault("default", t("bool")),
            }, t("bool")),
            stubMethod("remove", fqcn, &.{param("key", t("string"))}, t("void")),
        }, null);
    }

    // InputBag
    {
        const fqcn = http ++ "\\InputBag";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("get", fqcn, &.{
                param("key", t("string")),
                paramDefault("default", null),
            }, null),
            stubMethod("getInt", fqcn, &.{
                param("key", t("string")),
                paramDefault("default", t("int")),
            }, t("int")),
            stubMethod("getBoolean", fqcn, &.{
                param("key", t("string")),
                paramDefault("default", t("bool")),
            }, t("bool")),
            stubMethod("getString", fqcn, &.{
                param("key", t("string")),
                paramDefault("default", t("string")),
            }, t("string")),
            stubMethod("all", fqcn, &.{}, t("array")),
            stubMethod("has", fqcn, &.{param("key", t("string"))}, t("bool")),
        }, http ++ "\\ParameterBag");
    }
}

// ============================================================================
// Symfony Console
// ============================================================================

fn registerSymfonyConsoleStubs(allocator: std.mem.Allocator, sym_table: *SymbolTable) !void {
    const console = "Symfony\\Component\\Console";

    // Command
    {
        const fqcn = console ++ "\\Command\\Command";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("setName", fqcn, &.{param("name", t("string"))}, t(fqcn)),
            stubMethod("setDescription", fqcn, &.{param("description", t("string"))}, t(fqcn)),
            stubMethod("setHelp", fqcn, &.{param("help", t("string"))}, t(fqcn)),
            stubMethod("addArgument", fqcn, &.{
                param("name", t("string")),
                paramDefault("mode", tn("int")),
                paramDefault("description", t("string")),
                paramDefault("default", null),
            }, t(fqcn)),
            stubMethod("addOption", fqcn, &.{
                param("name", t("string")),
                paramDefault("shortcut", tn("string")),
                paramDefault("mode", tn("int")),
                paramDefault("description", t("string")),
                paramDefault("default", null),
            }, t(fqcn)),
            stubMethod("getName", fqcn, &.{}, tn("string")),
            stubMethod("getDescription", fqcn, &.{}, t("string")),
            stubMethod("isEnabled", fqcn, &.{}, t("bool")),
        }, null);
    }

    // InputInterface
    {
        const fqcn = console ++ "\\Input\\InputInterface";
        try addInterface(allocator, sym_table, fqcn, &.{
            stubAbstractMethod("getArgument", fqcn, &.{param("name", t("string"))}, null),
            stubAbstractMethod("getOption", fqcn, &.{param("name", t("string"))}, null),
            stubAbstractMethod("hasArgument", fqcn, &.{param("name", t("string"))}, t("bool")),
            stubAbstractMethod("hasOption", fqcn, &.{param("name", t("string"))}, t("bool")),
            stubAbstractMethod("isInteractive", fqcn, &.{}, t("bool")),
            stubAbstractMethod("getArguments", fqcn, &.{}, t("array")),
            stubAbstractMethod("getOptions", fqcn, &.{}, t("array")),
        });
    }

    // OutputInterface
    {
        const fqcn = console ++ "\\Output\\OutputInterface";
        try addInterface(allocator, sym_table, fqcn, &.{
            stubAbstractMethod("writeln", fqcn, &.{
                param("messages", null),
                paramDefault("options", t("int")),
            }, t("void")),
            stubAbstractMethod("write", fqcn, &.{
                param("messages", null),
                paramDefault("newline", t("bool")),
                paramDefault("options", t("int")),
            }, t("void")),
            stubAbstractMethod("isVerbose", fqcn, &.{}, t("bool")),
            stubAbstractMethod("isVeryVerbose", fqcn, &.{}, t("bool")),
            stubAbstractMethod("isDebug", fqcn, &.{}, t("bool")),
        });
    }

    // Style\\SymfonyStyle
    {
        const fqcn = console ++ "\\Style\\SymfonyStyle";
        try addClass(allocator, sym_table, fqcn, &.{
            stubMethod("title", fqcn, &.{param("message", t("string"))}, t("void")),
            stubMethod("section", fqcn, &.{param("message", t("string"))}, t("void")),
            stubMethod("success", fqcn, &.{param("message", null)}, t("void")),
            stubMethod("error", fqcn, &.{param("message", null)}, t("void")),
            stubMethod("warning", fqcn, &.{param("message", null)}, t("void")),
            stubMethod("note", fqcn, &.{param("message", null)}, t("void")),
            stubMethod("info", fqcn, &.{param("message", null)}, t("void")),
            stubMethod("table", fqcn, &.{
                param("headers", t("array")),
                param("rows", t("array")),
            }, t("void")),
            stubMethod("ask", fqcn, &.{
                param("question", t("string")),
                paramDefault("default", tn("string")),
            }, null),
            stubMethod("confirm", fqcn, &.{
                param("question", t("string")),
                paramDefault("default", t("bool")),
            }, t("bool")),
            stubMethod("progressStart", fqcn, &.{paramDefault("max", t("int"))}, t("void")),
            stubMethod("progressAdvance", fqcn, &.{paramDefault("step", t("int"))}, t("void")),
            stubMethod("progressFinish", fqcn, &.{}, t("void")),
            stubMethod("writeln", fqcn, &.{
                param("messages", null),
                paramDefault("type", t("int")),
            }, t("void")),
            stubMethod("write", fqcn, &.{
                param("messages", null),
                paramDefault("newline", t("bool")),
                paramDefault("type", t("int")),
            }, t("void")),
        }, null);
    }
}

// ============================================================================
// Symfony HttpKernel
// ============================================================================

fn registerSymfonyHttpKernelStubs(allocator: std.mem.Allocator, sym_table: *SymbolTable) !void {
    const kernel = "Symfony\\Component\\HttpKernel";

    // KernelInterface
    {
        const fqcn = kernel ++ "\\KernelInterface";
        try addInterface(allocator, sym_table, fqcn, &.{
            stubAbstractMethod("handle", fqcn, &.{
                param("request", t("Symfony\\Component\\HttpFoundation\\Request")),
                paramDefault("type", t("int")),
                paramDefault("catch", t("bool")),
            }, t("Symfony\\Component\\HttpFoundation\\Response")),
            stubAbstractMethod("boot", fqcn, &.{}, t("void")),
            stubAbstractMethod("shutdown", fqcn, &.{}, t("void")),
            stubAbstractMethod("getContainer", fqcn, &.{}, t("Symfony\\Component\\DependencyInjection\\ContainerInterface")),
            stubAbstractMethod("getEnvironment", fqcn, &.{}, t("string")),
            stubAbstractMethod("isDebug", fqcn, &.{}, t("bool")),
            stubAbstractMethod("getProjectDir", fqcn, &.{}, t("string")),
        });
    }
}

// ============================================================================
// PSR Interfaces
// ============================================================================

fn registerPsrStubs(allocator: std.mem.Allocator, sym_table: *SymbolTable) !void {
    // PSR-3 LoggerInterface
    {
        const fqcn = "Psr\\Log\\LoggerInterface";
        try addInterface(allocator, sym_table, fqcn, &.{
            stubAbstractMethod("emergency", fqcn, &.{
                param("message", t("string")),
                paramDefault("context", t("array")),
            }, t("void")),
            stubAbstractMethod("alert", fqcn, &.{
                param("message", t("string")),
                paramDefault("context", t("array")),
            }, t("void")),
            stubAbstractMethod("critical", fqcn, &.{
                param("message", t("string")),
                paramDefault("context", t("array")),
            }, t("void")),
            stubAbstractMethod("error", fqcn, &.{
                param("message", t("string")),
                paramDefault("context", t("array")),
            }, t("void")),
            stubAbstractMethod("warning", fqcn, &.{
                param("message", t("string")),
                paramDefault("context", t("array")),
            }, t("void")),
            stubAbstractMethod("notice", fqcn, &.{
                param("message", t("string")),
                paramDefault("context", t("array")),
            }, t("void")),
            stubAbstractMethod("info", fqcn, &.{
                param("message", t("string")),
                paramDefault("context", t("array")),
            }, t("void")),
            stubAbstractMethod("debug", fqcn, &.{
                param("message", t("string")),
                paramDefault("context", t("array")),
            }, t("void")),
            stubAbstractMethod("log", fqcn, &.{
                param("level", null),
                param("message", t("string")),
                paramDefault("context", t("array")),
            }, t("void")),
        });
    }

    // PSR-7 RequestInterface
    {
        const fqcn = "Psr\\Http\\Message\\RequestInterface";
        try addInterface(allocator, sym_table, fqcn, &.{
            stubAbstractMethod("getMethod", fqcn, &.{}, t("string")),
            stubAbstractMethod("withMethod", fqcn, &.{param("method", t("string"))}, t(fqcn)),
            stubAbstractMethod("getUri", fqcn, &.{}, t("Psr\\Http\\Message\\UriInterface")),
            stubAbstractMethod("withUri", fqcn, &.{
                param("uri", t("Psr\\Http\\Message\\UriInterface")),
                paramDefault("preserveHost", t("bool")),
            }, t(fqcn)),
            stubAbstractMethod("getRequestTarget", fqcn, &.{}, t("string")),
            stubAbstractMethod("withRequestTarget", fqcn, &.{param("requestTarget", null)}, t(fqcn)),
            stubAbstractMethod("getHeaders", fqcn, &.{}, t("array")),
            stubAbstractMethod("getHeader", fqcn, &.{param("name", t("string"))}, t("array")),
            stubAbstractMethod("getHeaderLine", fqcn, &.{param("name", t("string"))}, t("string")),
            stubAbstractMethod("hasHeader", fqcn, &.{param("name", t("string"))}, t("bool")),
            stubAbstractMethod("withHeader", fqcn, &.{
                param("name", t("string")),
                param("value", null),
            }, t(fqcn)),
            stubAbstractMethod("getBody", fqcn, &.{}, t("Psr\\Http\\Message\\StreamInterface")),
        });
    }

    // PSR-7 ResponseInterface
    {
        const fqcn = "Psr\\Http\\Message\\ResponseInterface";
        try addInterface(allocator, sym_table, fqcn, &.{
            stubAbstractMethod("getStatusCode", fqcn, &.{}, t("int")),
            stubAbstractMethod("withStatus", fqcn, &.{
                param("code", t("int")),
                paramDefault("reasonPhrase", t("string")),
            }, t(fqcn)),
            stubAbstractMethod("getReasonPhrase", fqcn, &.{}, t("string")),
            stubAbstractMethod("getHeaders", fqcn, &.{}, t("array")),
            stubAbstractMethod("getHeader", fqcn, &.{param("name", t("string"))}, t("array")),
            stubAbstractMethod("getHeaderLine", fqcn, &.{param("name", t("string"))}, t("string")),
            stubAbstractMethod("hasHeader", fqcn, &.{param("name", t("string"))}, t("bool")),
            stubAbstractMethod("withHeader", fqcn, &.{
                param("name", t("string")),
                param("value", null),
            }, t(fqcn)),
            stubAbstractMethod("getBody", fqcn, &.{}, t("Psr\\Http\\Message\\StreamInterface")),
        });
    }

    // PSR-11 ContainerInterface
    {
        const fqcn = "Psr\\Container\\ContainerInterface";
        try addInterface(allocator, sym_table, fqcn, &.{
            stubAbstractMethod("get", fqcn, &.{param("id", t("string"))}, null),
            stubAbstractMethod("has", fqcn, &.{param("id", t("string"))}, t("bool")),
        });
    }

    // PSR-6 CacheItemPoolInterface
    {
        const fqcn = "Psr\\Cache\\CacheItemPoolInterface";
        try addInterface(allocator, sym_table, fqcn, &.{
            stubAbstractMethod("getItem", fqcn, &.{param("key", t("string"))}, t("Psr\\Cache\\CacheItemInterface")),
            stubAbstractMethod("getItems", fqcn, &.{paramDefault("keys", t("array"))}, t("iterable")),
            stubAbstractMethod("hasItem", fqcn, &.{param("key", t("string"))}, t("bool")),
            stubAbstractMethod("clear", fqcn, &.{}, t("bool")),
            stubAbstractMethod("deleteItem", fqcn, &.{param("key", t("string"))}, t("bool")),
            stubAbstractMethod("deleteItems", fqcn, &.{param("keys", t("array"))}, t("bool")),
            stubAbstractMethod("save", fqcn, &.{param("item", t("Psr\\Cache\\CacheItemInterface"))}, t("bool")),
        });
    }
}

// ============================================================================
// Tests
// ============================================================================

test "framework stubs register without error" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    try registerFrameworkStubs(allocator, &sym_table);

    // Verify key classes exist
    try std.testing.expect(sym_table.classes.contains("Shopware\\Core\\Framework\\DataAbstractionLayer\\EntityRepository"));
    try std.testing.expect(sym_table.classes.contains("Doctrine\\DBAL\\Connection"));
    try std.testing.expect(sym_table.classes.contains("Doctrine\\ORM\\EntityManager"));
    try std.testing.expect(sym_table.classes.contains("Symfony\\Component\\HttpFoundation\\Request"));
    try std.testing.expect(sym_table.classes.contains("Symfony\\Component\\HttpFoundation\\Response"));
    try std.testing.expect(sym_table.classes.contains("Symfony\\Component\\Console\\Command\\Command"));

    // Verify key interfaces exist
    try std.testing.expect(sym_table.interfaces.contains("Doctrine\\ORM\\EntityManagerInterface"));
    try std.testing.expect(sym_table.interfaces.contains("Symfony\\Component\\DependencyInjection\\ContainerInterface"));
    try std.testing.expect(sym_table.interfaces.contains("Psr\\Log\\LoggerInterface"));
    try std.testing.expect(sym_table.interfaces.contains("Psr\\Container\\ContainerInterface"));
}

test "framework stubs have expected methods" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    try registerFrameworkStubs(allocator, &sym_table);

    // Check Doctrine Connection methods
    const conn = sym_table.getClass("Doctrine\\DBAL\\Connection").?;
    try std.testing.expect(conn.methods.contains("executeStatement"));
    try std.testing.expect(conn.methods.contains("executeQuery"));
    try std.testing.expect(conn.methods.contains("createQueryBuilder"));
    try std.testing.expect(conn.methods.contains("beginTransaction"));

    // Check Shopware EntityRepository methods
    const repo = sym_table.getClass("Shopware\\Core\\Framework\\DataAbstractionLayer\\EntityRepository").?;
    try std.testing.expect(repo.methods.contains("search"));
    try std.testing.expect(repo.methods.contains("create"));
    try std.testing.expect(repo.methods.contains("update"));
    try std.testing.expect(repo.methods.contains("delete"));

    // Check Criteria methods
    const criteria = sym_table.getClass("Shopware\\Core\\Framework\\DataAbstractionLayer\\Search\\Criteria").?;
    try std.testing.expect(criteria.methods.contains("addFilter"));
    try std.testing.expect(criteria.methods.contains("addSorting"));
    try std.testing.expect(criteria.methods.contains("addAssociation"));

    // Check Doctrine ORM EntityRepository has findBy
    const orm_repo = sym_table.getClass("Doctrine\\ORM\\EntityRepository").?;
    try std.testing.expect(orm_repo.methods.contains("findBy"));
    try std.testing.expect(orm_repo.methods.contains("findOneBy"));
    try std.testing.expect(orm_repo.methods.contains("find"));
}

test "framework stubs don't override existing symbols" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    // Pre-populate with a user-defined class
    var user_class = ClassSymbol.init(allocator, "Doctrine\\DBAL\\Connection");
    user_class.file_path = "vendor/doctrine/dbal/src/Connection.php";
    try user_class.addMethod(.{
        .name = "customMethod",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "Doctrine\\DBAL\\Connection",
        .file_path = "vendor/doctrine/dbal/src/Connection.php",
    });
    try sym_table.addClass(user_class);

    // Register stubs — should NOT override the user class
    try registerFrameworkStubs(allocator, &sym_table);

    // The original user class should still be there with its custom method
    const conn = sym_table.getClass("Doctrine\\DBAL\\Connection").?;
    try std.testing.expect(conn.methods.contains("customMethod"));
    // Should NOT have the stub methods since original was preserved
    try std.testing.expect(!conn.methods.contains("executeStatement"));
}

test "framework stubs method signatures are correct" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    try registerFrameworkStubs(allocator, &sym_table);

    // Check executeStatement has correct return type
    const conn = sym_table.getClass("Doctrine\\DBAL\\Connection").?;
    const exec_stmt = conn.methods.getPtr("executeStatement").?;
    try std.testing.expect(exec_stmt.return_type != null);
    try std.testing.expectEqualStrings("int", exec_stmt.return_type.?.base_type);

    // Check executeStatement has correct parameters
    try std.testing.expectEqual(@as(usize, 3), exec_stmt.parameters.len);
    try std.testing.expectEqualStrings("sql", exec_stmt.parameters[0].name);
    try std.testing.expectEqualStrings("string", exec_stmt.parameters[0].type_info.?.base_type);

    // Check getRepository returns EntityRepository
    const em = sym_table.getClass("Doctrine\\ORM\\EntityManager").?;
    const get_repo = em.methods.getPtr("getRepository").?;
    try std.testing.expect(get_repo.return_type != null);
    try std.testing.expectEqualStrings("Doctrine\\ORM\\EntityRepository", get_repo.return_type.?.base_type);
}

test "EntityRepository::search returns EntitySearchResult" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    try registerFrameworkStubs(allocator, &sym_table);

    const repo = sym_table.getClass("Shopware\\Core\\Framework\\DataAbstractionLayer\\EntityRepository").?;
    const search = repo.methods.getPtr("search").?;
    try std.testing.expect(search.return_type != null);
    try std.testing.expectEqualStrings(
        "Shopware\\Core\\Framework\\DataAbstractionLayer\\Search\\EntitySearchResult",
        search.return_type.?.base_type,
    );
    // search takes (Criteria, Context)
    try std.testing.expectEqual(@as(usize, 2), search.parameters.len);
    try std.testing.expectEqualStrings("criteria", search.parameters[0].name);
    try std.testing.expectEqualStrings("context", search.parameters[1].name);
}

test "Connection::executeStatement returns int" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    try registerFrameworkStubs(allocator, &sym_table);

    const conn = sym_table.getClass("Doctrine\\DBAL\\Connection").?;
    const exec_stmt = conn.methods.getPtr("executeStatement").?;
    try std.testing.expect(exec_stmt.return_type != null);
    try std.testing.expectEqualStrings("int", exec_stmt.return_type.?.base_type);
    try std.testing.expectEqual(@as(usize, 3), exec_stmt.parameters.len);
    try std.testing.expectEqualStrings("sql", exec_stmt.parameters[0].name);
}

test "Criteria::addFilter returns self" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    try registerFrameworkStubs(allocator, &sym_table);

    const criteria = sym_table.getClass("Shopware\\Core\\Framework\\DataAbstractionLayer\\Search\\Criteria").?;
    const add_filter = criteria.methods.getPtr("addFilter").?;
    try std.testing.expect(add_filter.return_type != null);
    // addFilter returns Criteria (self)
    try std.testing.expectEqualStrings(
        "Shopware\\Core\\Framework\\DataAbstractionLayer\\Search\\Criteria",
        add_filter.return_type.?.base_type,
    );
}

test "framework stubs resolve through inheritance" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    try registerFrameworkStubs(allocator, &sym_table);
    try sym_table.resolveInheritance();

    // JsonResponse should inherit Response methods
    const json_resp = sym_table.getClass("Symfony\\Component\\HttpFoundation\\JsonResponse").?;
    // Own method
    try std.testing.expect(json_resp.all_methods.contains("setData"));
    // Inherited from Response
    try std.testing.expect(json_resp.all_methods.contains("getStatusCode"));
    try std.testing.expect(json_resp.all_methods.contains("send"));
}
