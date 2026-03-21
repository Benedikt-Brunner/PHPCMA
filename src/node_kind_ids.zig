const ts = @import("tree-sitter");

/// Pre-cached tree-sitter node symbol IDs for fast integer comparison
/// instead of string comparison in hot-path traversal.
pub const NodeKindIds = struct {
    // Top-level declarations (SymbolCollector.traverseNode)
    namespace_definition: u16,
    namespace_use_declaration: u16,
    class_declaration: u16,
    interface_declaration: u16,
    trait_declaration: u16,
    function_definition: u16,

    // Class body members
    method_declaration: u16,
    property_declaration: u16,
    use_declaration: u16,

    // Use statement parsing
    namespace_use_clause: u16,
    namespace_aliasing_clause: u16,

    // Extends/implements
    base_clause: u16,
    class_interface_clause: u16,

    // Names
    name: u16,
    qualified_name: u16,
    namespace_name: u16,

    // Type nodes
    named_type: u16,
    optional_type: u16,
    union_type: u16,

    // Modifiers
    visibility_modifier: u16,
    static_modifier: u16,
    abstract_modifier: u16,
    final_modifier: u16,
    readonly_modifier: u16,

    // Property/parameter nodes
    property_element: u16,
    simple_parameter: u16,
    variadic_parameter: u16,
    property_promotion_parameter: u16,

    // Call expressions (CallAnalyzer.traverseNode)
    member_call_expression: u16,
    scoped_call_expression: u16,
    function_call_expression: u16,
    assignment_expression: u16,

    // Other
    compound_statement: u16,
    comment: u16,

    pub fn init(lang: *const ts.Language) NodeKindIds {
        return .{
            .namespace_definition = lang.idForNodeKind("namespace_definition", true),
            .namespace_use_declaration = lang.idForNodeKind("namespace_use_declaration", true),
            .class_declaration = lang.idForNodeKind("class_declaration", true),
            .interface_declaration = lang.idForNodeKind("interface_declaration", true),
            .trait_declaration = lang.idForNodeKind("trait_declaration", true),
            .function_definition = lang.idForNodeKind("function_definition", true),

            .method_declaration = lang.idForNodeKind("method_declaration", true),
            .property_declaration = lang.idForNodeKind("property_declaration", true),
            .use_declaration = lang.idForNodeKind("use_declaration", true),

            .namespace_use_clause = lang.idForNodeKind("namespace_use_clause", true),
            .namespace_aliasing_clause = lang.idForNodeKind("namespace_aliasing_clause", true),

            .base_clause = lang.idForNodeKind("base_clause", true),
            .class_interface_clause = lang.idForNodeKind("class_interface_clause", true),

            .name = lang.idForNodeKind("name", true),
            .qualified_name = lang.idForNodeKind("qualified_name", true),
            .namespace_name = lang.idForNodeKind("namespace_name", true),

            .named_type = lang.idForNodeKind("named_type", true),
            .optional_type = lang.idForNodeKind("optional_type", true),
            .union_type = lang.idForNodeKind("union_type", true),

            .visibility_modifier = lang.idForNodeKind("visibility_modifier", true),
            .static_modifier = lang.idForNodeKind("static_modifier", true),
            .abstract_modifier = lang.idForNodeKind("abstract_modifier", true),
            .final_modifier = lang.idForNodeKind("final_modifier", true),
            .readonly_modifier = lang.idForNodeKind("readonly_modifier", true),

            .property_element = lang.idForNodeKind("property_element", true),
            .simple_parameter = lang.idForNodeKind("simple_parameter", true),
            .variadic_parameter = lang.idForNodeKind("variadic_parameter", true),
            .property_promotion_parameter = lang.idForNodeKind("property_promotion_parameter", true),

            .member_call_expression = lang.idForNodeKind("member_call_expression", true),
            .scoped_call_expression = lang.idForNodeKind("scoped_call_expression", true),
            .function_call_expression = lang.idForNodeKind("function_call_expression", true),
            .assignment_expression = lang.idForNodeKind("assignment_expression", true),

            .compound_statement = lang.idForNodeKind("compound_statement", true),
            .comment = lang.idForNodeKind("comment", true),
        };
    }
};
