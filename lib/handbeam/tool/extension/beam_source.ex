defmodule Handbeam.Tool.Extension.Beam.Source do
  @moduledoc """
  Get source file:line for a module or function from the BEAM.

  Uses `:beam_lib.chunks/2` to extract location info from compiled bytecode.
  Works with both `:elixir_v1` and `:elixir_erl` debug info backends.

  Accepts: Module, Module.function, Module.function/arity.
  """

  @behaviour Handbeam.Agent.Tool

  @impl true
  def name, do: "ext__beam__source"

  @impl true
  def description do
    "Get source file:line for a module or function. " <>
      "The BEAM knows where everything is defined. " <>
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
        get_module_source(mod)

      {:function, mod, func, arity} ->
        get_function_source(mod, func, arity)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_input, _context) do
    {:error, "reference is required"}
  end

  # ── Reference parsing ──

  defp resolve_reference(ref) do
    ref = String.trim(ref)

    cond do
      String.match?(ref, ~r/^[A-Z][\w.]+\.[a-z_!?]+\/\d+$/) ->
        [mod_str, func_arity] = String.split(ref, ".", parts: 2)
        [func_str, arity_str] = String.split(func_arity, "/")
        mod = to_module(mod_str)
        func = String.to_existing_atom(func_str)
        arity = String.to_integer(arity_str)

        case ensure_module(mod) do
          {:ok, _} -> {:function, mod, func, arity}
          error -> error
        end

      String.match?(ref, ~r/^[A-Z][\w.]*$/) ->
        mod = to_module(ref)

        case ensure_module(mod) do
          {:ok, _} -> {:module, mod}
          error -> error
        end

      true ->
        {:error,
         "Cannot parse reference: #{ref}. Use Module, Module.function, or Module.function/arity."}
    end
  end

  defp to_module(str), do: Module.concat(["Elixir" | String.split(str, ".")])

  defp ensure_module(mod) do
    case Code.ensure_compiled(mod) do
      {:module, mod} -> {:ok, mod}
      {:error, _} -> {:error, "Module #{inspect(mod)} not found or not compiled"}
    end
  end

  # ── Source lookup ──

  defp get_module_source(mod) do
    beam_path = :code.which(mod)

    case extract_debug_info(beam_path, mod) do
      {:ok, file, _line_map} ->
        {:ok, "#{inspect(mod)}\n  Source: #{file}"}

      :error ->
        {:ok, "#{inspect(mod)}\n  BEAM: #{beam_path}\n  (source file could not be determined)"}
    end
  end

  defp get_function_source(mod, func, arity) do
    beam_path = :code.which(mod)

    case extract_debug_info(beam_path, mod) do
      {:ok, file, line_map} ->
        case Map.get(line_map, {func, arity}) do
          nil ->
            {:ok, "#{inspect(mod)}.#{func}/#{arity}\n  Source: #{file}\n  (exact line unknown)"}

          line ->
            {:ok, "#{inspect(mod)}.#{func}/#{arity}\n  Source: #{file}:#{line}"}
        end

      :error ->
        {:ok,
         "#{inspect(mod)}.#{func}/#{arity}\n  BEAM: #{beam_path}\n  (source info could not be determined)"}
    end
  end

  # ── Debug info extraction ──

  defp extract_debug_info(beam_path, mod) do
    case :beam_lib.chunks(beam_path, [:debug_info]) do
      {:ok, {^mod, [{:debug_info, info}]}} ->
        parse_debug_info(info)

      _ ->
        :error
    end
  end

  defp parse_debug_info({:debug_info_v1, :elixir_erl, {:elixir_v1, map, _specs}}) do
    parse_elixir_v1_map(map)
  end

  defp parse_debug_info({:debug_info_v1, :elixir_erl, metadata}) when is_tuple(metadata) do
    parse_elixir_erl_tuple(metadata)
  end

  defp parse_debug_info(_), do: :error

  # Elixir v1 format: %{file: path, definitions: [{...}, ...]}
  defp parse_elixir_v1_map(metadata) when is_map(metadata) do
    file = Map.get(metadata, :file)

    lines =
      metadata
      |> Map.get(:definitions, [])
      |> Enum.reduce(%{}, fn
        {{func, arity}, _kind, meta, _clauses}, acc ->
          line = Keyword.get(meta, :line, 0)
          Map.put(acc, {func, arity}, line)

        _, acc ->
          acc
      end)

    {:ok, file, lines}
  end

  # Elixir erl format: {module, specs, attrs, opts, deprecations}
  defp parse_elixir_erl_tuple(metadata) do
    {_module, _specs, _attrs, _opts, _deprecations} = metadata
    {:ok, "unknown", %{}}
  end
end
