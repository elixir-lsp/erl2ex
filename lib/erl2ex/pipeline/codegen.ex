# This is the final stage of the pipeline, after conversion.
# It takes as input a data structure as defined in ex_data.ex that includes
# Elixir AST and some accompanying metadata, and generates Elixir source code.

defmodule Erl2exVendored.Pipeline.Codegen do

  @moduledoc false

  alias Erl2exVendored.Pipeline.ExAttr
  alias Erl2exVendored.Pipeline.ExComment
  alias Erl2exVendored.Pipeline.ExDirective
  alias Erl2exVendored.Pipeline.ExFunc
  alias Erl2exVendored.Pipeline.ExHeader
  alias Erl2exVendored.Pipeline.ExImport
  alias Erl2exVendored.Pipeline.ExMacro
  alias Erl2exVendored.Pipeline.ExModule
  alias Erl2exVendored.Pipeline.ExRecord
  alias Erl2exVendored.Pipeline.ExSpec
  alias Erl2exVendored.Pipeline.ExType


  # Generate code and write to the given IO.

  def to_io(ex_module, io, opts \\ []) do
    opts
      |> build_context
      |> write_module(ex_module, io)
    :ok
  end


  # Generate code and return a generated string.

  def to_str(ex_module, opts \\ []) do
    {:ok, io} = StringIO.open("")
    to_io(ex_module, io, opts)
    {:ok, {_, str}} = StringIO.close(io)
    str
  end


  # An internal codegen context structure used to decide indentation and
  # vertical whitespace.

  defmodule Context do
    @moduledoc false
    defstruct(
      # The current indentation level (1 level = 2 spaces)
      indent: 0,
      # The kind of text last generated.
      last_form: :start,
      # A prefix string for environment variables used to define macros.
      define_prefix: "",
      # A string to pass to Application.get_env, or nil to use System.get_env.
      defines_from_config: nil
    )
  end


  # Initializes the context struct given options.

  defp build_context(opts) do
    defines_from_config = Keyword.get(opts, :defines_from_config, nil)
    defines_from_config =
      if is_binary(defines_from_config) do
        String.to_atom(defines_from_config)
      else
        defines_from_config
      end
    %Context{
      define_prefix: Keyword.get(opts, :define_prefix, "DEFINE_"),
      defines_from_config: defines_from_config
    }
  end


  # Update the indent level.

  def increment_indent(context) do
    %Context{context | indent: context.indent + 1}
  end

  def decrement_indent(context) do
    %Context{context | indent: context.indent - 1}
  end


  # Writes an Elixir module to the given IO, in the given context.

  # This version is used when there is no module name. We write the forms but
  # no defmodule.
  defp write_module(context, %ExModule{name: nil, forms: forms, file_comments: file_comments}, io) do
    context
      |> write_comment_list(file_comments, :structure_comments, io)
      |> foreach(forms, io, &write_form/3)
  end

  # This version is used when there is a module name. We write the entire
  # module structure including defmodule.
  defp write_module(context, %ExModule{name: name, forms: forms, file_comments: file_comments, comments: comments}, io) do
    context
      |> write_comment_list(file_comments, :structure_comments, io)
      |> write_comment_list(comments, :module_comments, io)
      |> skip_lines(:module_begin, io)
      |> write_string("defmodule :#{to_string(name)} do", io)
      |> increment_indent
      |> foreach(forms, io, &write_form/3)
      |> decrement_indent
      |> skip_lines(:module_end, io)
      |> write_string("end", io)
  end


  # Dispatcher for writing the Elixir equivalent of an Erlang form.

  # This version writes the module header pseudo-form, which includes a
  # bunch of macros and other prelude code that may be auto-generated by
  # the transpiler.
  defp write_form(context, header = %ExHeader{}, io) do
    context =
      if header.use_bitwise do
        context
          |> skip_lines(:attr, io)
          |> write_string("use Bitwise, only_operators: true", io)
      else
        context
      end
    context = context
      |> foreach(header.init_macros, fn(ctx, {name, defined_name}) ->
        ctx = ctx |> skip_lines(:attr, io)
        env_name = ctx.define_prefix <> to_string(name)
        get_env_syntax = if ctx.defines_from_config do
          "Application.get_env(#{inspect(ctx.defines_from_config)}, #{env_name |> String.to_atom |> inspect})"
        else
          "System.get_env(#{inspect(env_name)})"
        end
        ctx |> write_string("@#{defined_name} #{get_env_syntax} != nil", io)
      end)
    context =
      if not Enum.empty?(header.records) or header.has_is_record do
        context2 = context
          |> skip_lines(:attr, io)
          |> write_string("require Record", io)
        context2 =
          if header.record_size_macro != nil do
            context2
              |> skip_lines(:attr, io)
              |> write_string("defmacrop #{header.record_size_macro}(data_attr) do", io)
              |> increment_indent
              |> write_string("__MODULE__ |> Module.get_attribute(data_attr) |> Enum.count |> +(1)", io)
              |> decrement_indent
              |> write_string("end", io)
          else
            context2
          end
        if header.record_index_macro != nil do
          context2
            |> skip_lines(:attr, io)
            |> write_string("defmacrop #{header.record_index_macro}(data_attr, field) do", io)
            |> increment_indent
            |> write_string("index = __MODULE__ |> Module.get_attribute(data_attr) |> Enum.find_index(&(&1 ==field))", io)
            |> write_string("if index == nil, do: 0, else: index + 1", io)
            |> decrement_indent
            |> write_string("end", io)
        else
          context2
        end
      else
        context
      end
    if header.macro_dispatcher != nil do
      context
        |> skip_lines(:attr, io)
        |> write_string("defmacrop #{header.macro_dispatcher}(name, args) when is_atom(name), do:", io)
        |> increment_indent
        |> write_string("{Module.get_attribute(__MODULE__, name), [], args}", io)
        |> decrement_indent
        |> write_string("defmacrop #{header.macro_dispatcher}(macro, args), do:", io)
        |> increment_indent
        |> write_string("{Macro.expand(macro, __CALLER__), [], args}", io)
        |> decrement_indent
    else
      context
    end
  end

  # This version writes a comment.
  defp write_form(context, %ExComment{comments: comments}, io) do
    context
      |> write_comment_list(comments, :structure_comments, io)
  end

  # This version writes a function definition.
  defp write_form(
    context,
    %ExFunc{
      comments: comments,
      clauses: [first_clause | remaining_clauses],
      public: public,
      specs: specs
    },
    io)
  do
    context
      |> write_comment_list(comments, :func_header, io)
      |> write_func_specs(specs, io)
      |> write_func_clause(public, first_clause, :func_clause_first, io)
      |> foreach(remaining_clauses, fn (ctx, clause) ->
        write_func_clause(ctx, public, clause, :func_clause, io)
      end)
  end

  # This version writes an attribute definition
  defp write_form(context, %ExAttr{name: name, register: register, arg: arg, comments: comments}, io) do
    context
      |> skip_lines(:attr, io)
      |> foreach(comments, io, &write_string/3)
      |> write_raw_attr(name, register, arg, io)
  end

  # This version writes most directives
  defp write_form(context, %ExDirective{directive: directive, name: name, comments: comments}, io) do
    context
      |> skip_lines(:directive, io)
      |> foreach(comments, io, &write_string/3)
      |> write_raw_directive(directive, name, io)
  end

  # This version writes an import directive
  defp write_form(context, %ExImport{module: module, funcs: funcs, comments: comments}, io) do
    context
      |> skip_lines(:attr, io)
      |> foreach(comments, io, &write_string/3)
      |> write_string("import #{expr_to_string(module)}, only: #{expr_to_string(funcs)}", io)
  end

  # This version writes an attribute definition
  defp write_form(context, %ExRecord{tag: tag, macro: macro, data_attr: data_attr, fields: fields, comments: comments}, io) do
    field_names = fields |> Enum.map(&(elem(&1, 0)))
    context
      |> skip_lines(:attr, io)
      |> foreach(comments, io, &write_string/3)
      |> write_string("@#{data_attr} #{expr_to_string(field_names)}", io)
      |> write_string("Record.defrecordp #{expr_to_string(macro)}, #{expr_to_string(tag)}, #{expr_to_string(fields)}", io)
  end

  # This version writes a type definition
  defp write_form(context, %ExType{kind: kind, signature: signature, defn: defn, comments: comments}, io) do
    context
      |> skip_lines(:attr, io)
      |> foreach(comments, io, &write_string/3)
      |> write_string("@#{kind} #{expr_to_string(signature)} :: #{expr_to_string(defn)}", io)
  end

  # This version writes a function spec
  defp write_form(context, %ExSpec{kind: kind, specs: specs, comments: comments}, io) do
    context
      |> skip_lines(:attr, io)
      |> foreach(comments, io, &write_string/3)
      |> foreach(specs, fn(ctx, spec) ->
        write_string(ctx, "@#{kind} #{expr_to_string(spec)}", io)
      end)
  end

  # This version writes a macro
  defp write_form(
    context,
    %ExMacro{
      macro_name: macro_name,
      signature: signature,
      tracking_name: tracking_name,
      dispatch_name: dispatch_name,
      stringifications: stringifications,
      expr: expr,
      guard_expr: guard_expr,
      comments: comments
    },
    io)
  do
    context = context
      |> write_comment_list(comments, :func_header, io)
      |> skip_lines(:func_clause_first, io)
      |> write_string("defmacrop #{signature_to_string(signature)} do", io)
      |> increment_indent
      |> foreach(stringifications, fn(ctx, {var, str}) ->
        write_string(ctx, "#{str} = Macro.to_string(quote do: unquote(#{var})) |> String.to_charlist", io)
      end)
    context =
      if guard_expr != nil do
        context
          |> write_string("if Macro.Env.in_guard?(__CALLER__) do", io)
          |> increment_indent
          |> write_string("quote do", io)
          |> increment_indent
          |> write_string(expr_to_string(guard_expr), io)
          |> decrement_indent
          |> write_string("end", io)
          |> decrement_indent
          |> write_string("else", io)
          |> increment_indent
      else
        context
      end
    context = context
      |> write_string("quote do", io)
      |> increment_indent
      |> write_string(expr_to_string(expr), io)
      |> decrement_indent
      |> write_string("end", io)
    context =
      if guard_expr != nil do
        context
          |> decrement_indent
          |> write_string("end", io)
      else
        context
      end
    context = context
      |> decrement_indent
      |> write_string("end", io)
    context =
      if tracking_name != nil do
        context
          |> write_string("@#{tracking_name} true", io)
      else
        context
      end
    context =
      if dispatch_name != nil do
        context
          |> write_string("@#{dispatch_name} :#{macro_name}", io)
      else
        context
      end
    context
  end


  # Write an attribute definition to the given IO.

  defp write_raw_attr(context, name, register, arg, io) do
    context =
      if register do
        context
          |> write_string("Module.register_attribute(__MODULE__, #{expr_to_string(name)}, persist: true, accumulate: true)", io)
      else
        context
      end
    context
      |> write_string("@#{name} #{expr_to_string(arg)}", io)
  end


  # Write the Elixir equivalent of a preprocessor control structure directive.

  # The undef directive.
  defp write_raw_directive(context, :undef, tracking_name, io) do
    context
      |> write_string("@#{tracking_name} false", io)
  end

  # The ifdef directive.
  defp write_raw_directive(context, :ifdef, tracking_name, io) do
    context
      |> write_string("if @#{tracking_name} do", io)
  end

  # The ifndef directive.
  defp write_raw_directive(context, :ifndef, tracking_name, io) do
    context
      |> write_string("if not @#{tracking_name} do", io)
  end

  # The else directive.
  defp write_raw_directive(context, :else, nil, io) do
    context
      |> write_string("else", io)
  end

  # The endif directive.
  defp write_raw_directive(context, :endif, nil, io) do
    context
      |> write_string("end", io)
  end


  # Write a list of full-line comments.

  defp write_comment_list(context, [], _form_type, _io), do: context
  defp write_comment_list(context, comments, form_type, io) do
    context
      |> skip_lines(form_type, io)
      |> foreach(comments, io, &write_string/3)
  end


  # Write a list of function specification clauses.

  defp write_func_specs(context, [], _io), do: context
  defp write_func_specs(context, specs, io) do
    context
      |> skip_lines(:func_specs, io)
      |> foreach(specs, fn(ctx, spec) ->
        write_string(ctx, "@spec #{expr_to_string(spec)}", io)
      end)
  end


  # Write a single function clause (i.e. a def or defp)

  defp write_func_clause(context, public, clause, form_type, io) do
    decl = if public, do: "def", else: "defp"
    sig = clause.signature
    context = context
      |> skip_lines(form_type, io)
      |> foreach(clause.comments, io, &write_string/3)
    context = context
      |> write_string("#{decl} #{signature_to_string(sig)} do", io)
      |> increment_indent
      |> foreach(clause.exprs, fn (ctx, expr) ->
        write_string(ctx, expr_to_string(expr), io)
      end)
      |> decrement_indent
      |> write_string("end", io)
    context
  end


  # Low-level function that writes a string, handling indent.

  defp write_string(context, str, io) do
    indent = String.duplicate("  ", context.indent)
    str
      |> String.split("\n")
      |> Enum.each(fn line ->
        IO.write(io, "#{indent}#{line}\n")
      end)
    context
  end


  # Performs the given operation on elements of the given list, updating the
  # context and returning the final context value.

  defp foreach(context, list, io, func) do
    Enum.reduce(list, context, fn (e, ctx) -> func.(ctx, e, io) end)
  end

  defp foreach(context, list, func) do
    Enum.reduce(list, context, fn (e, ctx) -> func.(ctx, e) end)
  end


  # Inserts appropriate vertical whitespace, given a form type.

  defp skip_lines(context, cur_form, io) do
    lines = calc_skip_lines(context.last_form, cur_form)
    if lines > 0 do
      IO.puts(io, String.duplicate("\n", lines - 1))
    end
    %Context{context | last_form: cur_form}
  end


  # Computes the vertical whitespace between two form types.

  defp calc_skip_lines(:start, _), do: 0
  defp calc_skip_lines(:module_comments, :module_begin), do: 1
  defp calc_skip_lines(:module_begin, _), do: 1
  defp calc_skip_lines(_, :module_end), do: 1
  defp calc_skip_lines(:func_header, :func_specs), do: 1
  defp calc_skip_lines(:func_header, :func_clause_first), do: 1
  defp calc_skip_lines(:func_specs, :func_clause_first), do: 1
  defp calc_skip_lines(:func_clause_first, :func_clause), do: 1
  defp calc_skip_lines(:func_clause, :func_clause), do: 1
  defp calc_skip_lines(:attr, :attr), do: 1
  defp calc_skip_lines(_, _), do: 2


  # Generates code for a function signature.
  # Handles a special case where the signature ends with a keyword argument
  # block that includes "do:" as a keyword. Macro.to_string erroneously
  # generates a do block for that case, so we detect that case and modify the
  # generated string.

  defp signature_to_string({target, ctx, args} = expr) do
    str = expr_to_string(expr)
    if String.ends_with?(str, "\nend") do
      args = args |> List.update_at(-1, fn kwargs ->
        kwargs ++ [a: :a]
      end)
      {target, ctx, args}
        |> expr_to_string
        |> String.replace_suffix(", a: :a)", ")")
    else
      str
    end
  end


  # Given an Elixir AST, generate Elixir source code.
  # This wraps Macro.to_string but does a bit of customization.

  defp expr_to_string(expr) do
    Macro.to_string(expr, &modify_codegen/2)
  end


  # Codegen customization.

  # Custom codegen for character literals. There's a hack in conversion that
  # converts character literals to the illegal "?" variable name, with the
  # actual character in the metadata.
  defp modify_codegen({:"?", metadata, Elixir}, str) do
    case Keyword.get(metadata, :char) do
      nil -> str
      val -> << "?"::utf8, escape_char(val)::binary >>
    end
  end

  # Fallthrough for codegen
  defp modify_codegen(_ast, str) do
    str
  end


  # Escaped character literals.
  defp escape_char(?\\), do: "\\\\"
  defp escape_char(?\a), do: "\\a"
  defp escape_char(?\b), do: "\\b"
  defp escape_char(?\d), do: "\\d"
  defp escape_char(?\e), do: "\\e"
  defp escape_char(?\f), do: "\\f"
  defp escape_char(?\n), do: "\\n"
  defp escape_char(?\r), do: "\\r"
  defp escape_char(?\s), do: "\\s"
  defp escape_char(?\t), do: "\\t"
  defp escape_char(?\v), do: "\\v"
  defp escape_char(?\0), do: "\\0"
  defp escape_char(val), do: <<val::utf8>>


end
