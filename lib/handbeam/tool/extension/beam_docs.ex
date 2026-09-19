defmodule Handbeam.Tool.Extension.Beam.Docs do
  @moduledoc """
  Get documentation for a module or function from the running application.

  Returns exact docs for the exact versions in mix.lock.
  Accepts: Module, Module.function, Module.function/arity.
  """

  @behaviour Handbeam.Agent.Tool

  @impl true
  def name, do: "ext__beam__docs"

  @impl true
  def description do
    "Get documentation for a module or function from the running application. " <>
      "Accepts: Module, Module.function, Module.function/arity."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        reference: %{
          type: "string",
          description: "e.g. Enum, Enum.map, Enum.map/2"
        }
      },
      required: ["reference"]
    }
  end

  @impl true
  def execute(%{"reference" => ref}, _context) do
    case resolve_reference(ref) do
      {:module, mod} ->
        get_module_docs(mod)

      {:function, mod, func, arity} ->
        get_function_docs(mod, func, arity)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_input, _context) do
    {:error, "reference is required"}
  end

  # ── Reference parsing ──

  defp resolve_reference(ref) do
    try do
      ref = String.trim(ref)

      cond do
        # Module.function/arity
        String.match?(ref, ~r/^[A-Z][\w.]+\.[a-z_!?]+\/\d+$/) ->
          [mod_str, func_arity] = String.split(ref, ".", parts: 2)
          [func_str, arity_str] = String.split(func_arity, "/")
          mod = String.to_existing_atom("Elixir.#{mod_str}")
          func = String.to_existing_atom(func_str)
          arity = String.to_integer(arity_str)

          case ensure_module(mod) do
            {:ok, mod} -> {:function, mod, func, arity}
            error -> error
          end

        # Module.function (no arity)
        String.match?(ref, ~r/^[A-Z][\w.]+\.[a-z_!?]+$/) ->
          [mod_str, func_str] = String.split(ref, ".", parts: 2)
          mod = String.to_existing_atom("Elixir.#{mod_str}")
          func = String.to_existing_atom(func_str)

          case ensure_module(mod) do
            {:ok, mod} -> {:function, mod, func, nil}
            error -> error
          end

        # Just a Module
        String.match?(ref, ~r/^[A-Z][\w.]*$/) ->
          mod = String.to_existing_atom("Elixir.#{ref}")

          case ensure_module(mod) do
            {:ok, mod} -> {:module, mod}
            error -> error
          end

        true ->
          {:error,
           "Cannot parse reference: #{ref}. Use Module, Module.function, or Module.function/arity."}
      end
    rescue
      ArgumentError -> {:error, "Module or function not found: #{ref}"}
    end
  end

  defp ensure_module(mod) do
    case Code.ensure_compiled(mod) do
      {:module, mod} -> {:ok, mod}
      {:error, _} -> {:error, "Module #{inspect(mod)} not found or not compiled"}
    end
  end

  # ── Docs retrieval ──

  defp get_module_docs(mod) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _anno, _lang, _format, _module_doc, _metadata, docs} ->
        output = build_module_doc_output(mod, docs)
        {:ok, output}

      {:error, reason} ->
        {:error, "Could not fetch docs for #{inspect(mod)}: #{inspect(reason)}"}
    end
  end

  defp build_module_doc_output(mod, docs) when is_list(docs) do
    lines = [
      "# #{inspect(mod)}",
      "",
      "## Functions",
      ""
    ]

    func_lines =
      docs
      |> Enum.filter(fn
        {{:function, _, _}, _, _, _, _} -> true
        _ -> false
      end)
      |> Enum.flat_map(fn {{:function, name, arity}, _line, signature, doc, _metadata} ->
        sig = signature_to_string(signature)
        doc_str = doc_to_string(doc)

        [
          "### #{name}/#{arity}",
          "",
          "```elixir",
          sig,
          "```",
          "",
          doc_str,
          "",
          "---",
          ""
        ]
      end)

    total =
      docs
      |> Enum.filter(fn
        {{:function, _, _}, _, _, _, _} -> true
        _ -> false
      end)
      |> length()

    (lines ++ func_lines ++ ["Total: #{total} functions"])
    |> Enum.join("\n")
  end

  defp get_function_docs(mod, func, nil) do
    # No arity specified — find all arities
    case Code.fetch_docs(mod) do
      {:docs_v1, _anno, _lang, _format, _module_doc, _metadata, docs} ->
        matches =
          docs
          |> Enum.filter(fn
            {{:function, ^func, _}, _, _, _, _} -> true
            _ -> false
          end)

        if matches == [] do
          {:error, "Function #{inspect(mod)}.#{func} not found in docs"}
        else
          output = build_module_doc_output(mod, matches)
          {:ok, output}
        end

      {:error, reason} ->
        {:error, "Could not fetch docs: #{inspect(reason)}"}
    end
  end

  defp get_function_docs(mod, func, arity) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _anno, _lang, _format, _module_doc, _metadata, docs} ->
        match =
          Enum.find(docs, fn
            {{:function, ^func, ^arity}, _, _, _, _} -> true
            _ -> false
          end)

        case match do
          nil ->
            {:error, "Function #{inspect(mod)}.#{func}/#{arity} not found in docs"}

          {{:function, ^func, ^arity}, _line, signature, doc, _metadata} ->
            sig = signature_to_string(signature)
            doc_str = doc_to_string(doc)

            output = """
            # #{inspect(mod)}.#{func}/#{arity}

            ```elixir
            #{sig}
            ```

            #{doc_str}
            """

            {:ok, output}
        end

      {:error, reason} ->
        {:error, "Could not fetch docs: #{inspect(reason)}"}
    end
  end

  defp signature_to_string(signature) when is_list(signature) do
    signature
    |> Enum.map_join(", ", fn
      s when is_binary(s) -> s
      s -> inspect(s)
    end)
    |> then(&"`#{&1}`")
  end

  defp signature_to_string(signature), do: inspect(signature)

  defp doc_to_string(:none), do: "No documentation available."
  defp doc_to_string(:hidden), do: "Documentation is hidden."
  defp doc_to_string(doc) when is_binary(doc), do: doc

  defp doc_to_string(%{"en" => text}), do: text

  defp doc_to_string(map) when is_map(map) do
    Map.get(map, "en") || Map.get(map, "default") || inspect(map)
  end
end
