# How to use the compiler :
# HTMLHandler.Compiler.replace(html_text, %{"title" => "Toto"})
# in case of a nested map %{attr 1 => %{attr 2 => "toto"}}
# use the attr1_attr2

defmodule HTMLHandler.Compiler do

  defp linearize(m, prefix) do
      Enum.map(m, fn {k, v} ->
          if is_map(v) do
              linearize(v, if prefix == "" do k else prefix <> "_" <> k end)
          else {if prefix == "" do k else prefix <> "_" <> k end, v} end
      end) |> List.flatten()
  end

  defp linearize(m) do
      linearize(m, "") |> Enum.into(%{})
  end

  def replace(html, replacements) do
      replacements |>
      linearize() |>
      Enum.reduce(html, fn {key, value}, acc ->
          value = "#{value}" |> String.trim_leading("\n") |> String.replace("\n", "<br/>") 
          Regex.compile!("\\[" <> key <> "\\].*\\[\/" <> key <> "\\]") |>
          Regex.replace(acc, "#{value}")
      end)
  end

end