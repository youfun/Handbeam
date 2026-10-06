files =
  case System.get_env("HANDBEAM_CREDENCE_FILES") do
    nil ->
      Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/support/**/*.ex")

    path ->
      path
      |> File.read!()
      |> String.split("\n", trim: true)
  end

issues =
  Enum.flat_map(files, fn file ->
    code = File.read!(file)
    result = Credence.analyze(code, [])

    Enum.map(result.issues, fn issue ->
      {file, issue}
    end)
  end)

if issues == [] do
  IO.puts("Credence found no issues.")
else
  IO.puts("Credence findings:")

  Enum.each(issues, fn {file, issue} ->
    line = issue.meta[:line] || "?"
    IO.puts("#{file}:#{line} #{issue.rule} #{issue.message}")
  end)

  System.halt(1)
end
