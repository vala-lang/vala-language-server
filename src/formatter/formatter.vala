using Gee;

class Vls.Formatter : Object {
    private Pair<Vala.SourceFile, Compilation> input;
    private Lsp.FormattingOptions options;

    public Formatter (Lsp.FormattingOptions options, Pair<Vala.SourceFile, Compilation> input) {
        this.options = options;
        this.input = input;
    }

    public string? format (out Lsp.TextEdit edit, out Jsonrpc.ClientError error) {
        error = 0;
        edit = null;
        File cfg;
        try {
            cfg = this.generate_uncrustify_config ();
        } catch (Error e) {
            return "Error creating config: %s".printf (e.message);
        }
        var original = File.new_for_path (this.input.first.filename);
        var time = new DateTime.now_local ().to_unix ();
        var new_file = File.new_build_filename (Environment.get_tmp_dir (), "vls-format%lld.vala".printf (time));
        try {
            original.copy (new_file, FileCopyFlags.ALL_METADATA | FileCopyFlags.OVERWRITE, null, null);
        } catch (Error e) {
            return "Error copying file: %s".printf (e.message);
        }
        string sout;
        string serr;
        int exit;
        try {
            // The path in the flatpak GNOME-Builder is really really small
            // (Just /usr/bin:/bin), but what if uncrustify is in /usr/local?
            // We have to patch the path in a platform dependent way
            var spawn_args = new string[] { "/usr/local/bin/uncrustify", "-c", cfg.get_path (), "--replace", "--no-backup", new_file.get_path () };
            Process.spawn_sync (Environment.get_current_dir (),
                                spawn_args,
                                Environ.get (),
                                SpawnFlags.SEARCH_PATH,
                                null,
                                out sout,
                                out serr,
                                out exit);
        } catch (SpawnError e) {
            return "Error spawning uncrustify: %s (PATH=%s)".printf (e.message, Environment.get_variable ("PATH"));
        }
        if (exit != 0) {
            return "Uncrustify failed: %s".printf (serr);
        }
        var str = "";
        var n = 0;
        try {
            var reopened = File.new_for_path (new_file.get_path ());
            var iostream = reopened.open_readwrite ();
            var distream = new DataInputStream (iostream.input_stream);
            var sb = new StringBuilder ();
            string tmp = null;
            size_t len;
            while ((tmp = distream.read_line (out len)) != null) {
                sb.append (tmp).append_c ('\n');
                n++;
            }
            str = sb.str;
        } catch (Error e) {
            return "Error reading uncrustified file: %s".printf (e.message);
        }

        edit = new Lsp.TextEdit () {
            range = new Lsp.Range () {
                start = new Lsp.Position () {
                    line = 0,
                    character = 0
                },
                end = new Lsp.Position () {
                    line = n + 1,
                    // Just for the trailing newline
                    character = 1
                }
            },
            newText = str
        };
        try {
            new_file.@delete ();
            cfg.@delete ();
        } catch (Error e) {
            warning ("Error cleaning up: %s", e.message);
        }
        return null;
    }

    File generate_uncrustify_config () throws Error {
        var conf = new Gee.HashMap<string, string>();
        // https://github.com/uncrustify/uncrustify/blob/master/documentation/htdocs/default.cfg
        conf["indent_with_tabs"] = "%d".printf (options.insertSpaces ? 0 : 1);
        conf["nl_end_of_file"] = options.insertFinalNewline ? "force" : "remove";
        conf["nl_end_of_file_min"] = "%d".printf (options.trimFinalNewlines ? 1 : 0);
        conf["output_tab_size"] = "%u".printf (options.tabSize);
        conf["indent_columns"] = "4";
        conf["indent_align_string"] = "true";
        conf["indent_xml_string"] = "4";
        conf["indent_namespace"] = "true";
        conf["indent_class"] = "true";
        conf["indent_var_def_cont"] = "true";
        conf["indent_func_def_param"] = "true";
        conf["indent_func_proto_param"] = "true";
        conf["indent_func_class_param"] = "true";
        conf["indent_func_ctor_var_param"] = "true";
        conf["indent_template_param"] = "true";
        conf["indent_member"] = "1";
        conf["indent_paren_close"] = "2";
        conf["indent_align_assign"] = "false";
        conf["indent_oc_block_msg_xcode_style"] = "true";
        conf["indent_oc_block_msg_from_keyword"] = "true";
        conf["indent_oc_block_msg_from_colon"] = "true";
        conf["indent_oc_block_msg_from_caret"] = "true";
        conf["indent_oc_block_msg_from_brace"] = "true";
        conf["newlines"] = "auto";
        conf["sp_arith"] = "force";
        conf["sp_assign"] = "force";
        conf["sp_assign_default"] = "force";
        conf["sp_before_assign"] = "force";
        conf["sp_after_assign"] = "force";
        conf["sp_enum_assign"] = "force";
        conf["sp_enum_after_assign"] = "force";
        conf["sp_bool"] = "force";
        conf["sp_compare"] = "force";
        conf["sp_inside_paren"] = "remove";
        conf["sp_paren_paren"] = "remove";
        conf["sp_cparen_oparen"] = "force";
        conf["sp_paren_brace"] = "force";
        conf["sp_before_ptr_star"] = "remove";
        conf["sp_before_unnamed_ptr_star"] = "remove";
        conf["sp_between_ptr_star"] = "force";
        conf["sp_after_ptr_star"] = "force";
        conf["sp_after_ptr_star_func"] = "force";
        conf["sp_ptr_star_paren"] = "force";
        conf["sp_before_ptr_star_func"] = "force";
        conf["sp_before_byref"] = "force";
        conf["sp_after_byref_func"] = "remove";
        conf["sp_before_byref_func"] = "force";
        conf["sp_before_angle"] = "remove";
        conf["sp_inside_angle"] = "remove";
        conf["sp_after_angle"] = "remove";
        conf["sp_angle_paren"] = "force";
        conf["sp_angle_word"] = "force";
        conf["sp_before_sparen"] = "force";
        conf["sp_inside_sparen"] = "remove";
        conf["sp_after_sparen"] = "remove";
        conf["sp_sparen_brace"] = "force";
        conf["sp_special_semi"] = "remove";
        conf["sp_before_semi_for"] = "remove";
        conf["sp_before_semi_for_empty"] = "force";
        conf["sp_after_semi_for_empty"] = "force";
        conf["sp_before_square"] = "remove";
        conf["sp_before_squares"] = "remove";
        conf["sp_inside_square"] = "remove";
        conf["sp_after_comma"] = "force";
        conf["sp_before_ellipsis"] = "remove";
        conf["sp_after_class_colon"] = "force";
        conf["sp_before_class_colon"] = "force";
        conf["sp_after_constr_colon"] = "ignore";
        conf["sp_before_constr_colon"] = "ignore";
        conf["sp_after_operator"] = "force";
        conf["sp_after_cast"] = "force";
        conf["sp_inside_paren_cast"] = "remove";
        conf["sp_sizeof_paren"] = "force";
        conf["sp_inside_braces_enum"] = "force";
        conf["sp_inside_braces_struct"] = "force";
        conf["sp_inside_braces"] = "force";
        conf["sp_inside_braces_empty"] = "remove";
        conf["sp_type_func"] = "remove";
        conf["sp_func_proto_paren"] = "force";
        conf["sp_func_def_paren"] = "force";
        conf["sp_inside_fparens"] = "remove";
        conf["sp_inside_fparen"] = "remove";
        conf["sp_inside_tparen"] = "remove";
        conf["sp_after_tparen_close"] = "remove";
        conf["sp_square_fparen"] = "force";
        conf["sp_fparen_brace"] = "force";
        conf["sp_func_call_paren"] = "force";
        conf["sp_func_call_paren_empty"] = "force";
        // It is really "set func_call_user _"
        conf["set func_call_user"] = "C_ NC_ N_ Q_ _";
        conf["sp_func_class_paren"] = "force";
        conf["sp_return_paren"] = "force";
        conf["sp_attribute_paren"] = "force";
        conf["sp_defined_paren"] = "force";
        conf["sp_throw_paren"] = "force";
        conf["sp_after_throw"] = "force";
        conf["sp_catch_paren"] = "force";
        conf["sp_else_brace"] = "force";
        conf["sp_brace_else"] = "force";
        conf["sp_brace_typedef"] = "force";
        conf["sp_catch_brace"] = "force";
        conf["sp_brace_catch"] = "force";
        conf["sp_finally_brace"] = "force";
        conf["sp_brace_finally"] = "force";
        conf["sp_try_brace"] = "force";
        conf["sp_getset_brace"] = "force";
        conf["sp_word_brace_ns"] = "force";
        conf["sp_before_dc"] = "remove";
        conf["sp_after_dc"] = "remove";
        conf["sp_cond_colon"] = "force";
        conf["sp_cond_colon_before"] = "force";
        conf["sp_cond_question"] = "force";
        conf["sp_cond_question_after"] = "force";
        conf["sp_cond_ternary_short"] = "force";
        conf["sp_case_label"] = "force";
        conf["sp_cmt_cpp_start"] = "force";
        conf["sp_endif_cmt"] = "remove";
        conf["sp_after_new"] = "force";
        conf["sp_before_tr_cmt"] = "force";
        conf["align_keep_extra_space"] = "true";
        conf["nl_assign_leave_one_liners"] = "true";
        conf["nl_class_leave_one_liners"] = "true";
        conf["nl_enum_brace"] = "remove";
        conf["nl_struct_brace"] = "remove";
        conf["nl_union_brace"] = "remove";
        conf["nl_if_brace"] = "remove";
        conf["nl_brace_else"] = "remove";
        conf["nl_elseif_brace"] = "remove";
        conf["nl_else_brace"] = "remove";
        conf["nl_else_if"] = "remove";
        conf["nl_brace_finally"] = "remove";
        conf["nl_finally_brace"] = "remove";
        conf["nl_try_brace"] = "remove";
        conf["nl_getset_brace"] = "remove";
        conf["nl_for_brace"] = "remove";
        conf["nl_catch_brace"] = "remove";
        conf["nl_brace_catch"] = "remove";
        conf["nl_brace_square"] = "remove";
        conf["nl_brace_fparen"] = "remove";
        conf["nl_while_brace"] = "remove";
        conf["nl_using_brace"] = "remove";
        conf["nl_do_brace"] = "remove";
        conf["nl_brace_while"] = "remove";
        conf["nl_switch_brace"] = "remove";
        conf["nl_before_throw"] = "remove";
        conf["nl_namespace_brace"] = "remove";
        conf["nl_class_brace"] = "remove";
        conf["nl_class_init_args"] = "remove";
        conf["nl_class_init_args"] = "remove";
        conf["nl_func_type_name"] = "remove";
        conf["nl_func_type_name_class"] = "remove";
        conf["nl_func_proto_type_name"] = "remove";
        conf["nl_func_paren"] = "remove";
        conf["nl_func_def_paren"] = "remove";
        conf["nl_func_decl_start"] = "remove";
        conf["nl_func_def_start"] = "remove";
        conf["nl_func_decl_end"] = "remove";
        conf["nl_func_def_end"] = "remove";
        conf["nl_func_decl_empty"] = "remove";
        conf["nl_func_def_empty"] = "remove";
        conf["nl_fdef_brace"] = "remove";
        conf["nl_return_expr"] = "remove";
        conf["nl_after_func_proto_group"] = "2";
        conf["nl_after_func_body"] = "2";
        conf["nl_after_func_body_class"] = "2";
        conf["eat_blanks_before_close_brace"] = "true";
        conf["pp_indent_count"] = "0";
        var sb = new StringBuilder ();
        foreach (var entry in conf.entries) {
            sb.append (entry.key).append (" = ").append (entry.value).append ("\n");
        }
        FileIOStream ios;
        var file = File.new_tmp ("vls-uncrustify-XXXXXX.cfg", out ios);
        var dostream = new DataOutputStream (ios.output_stream);
        dostream.put_string (sb.str);
        return file;
    }
}

