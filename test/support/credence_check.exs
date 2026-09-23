files = Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/support/**/*.ex")

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
end
