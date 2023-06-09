# How to use the templater :
# use <template src="my_component.html"/> in the html and it will be replace on the server side
# then just go File.read!("my_html.html") |> HTMLHandler.Templater.replace()

defmodule HTMLHandler.Templater do
  
    require Logger

    def replace(html) do
        to_replace = Regex.scan(~r/<\s*template\s*src\s*=\s*"\s*([a-zA-Z\._\-\/]+)\s*"\s*\/\s*>/, html)
        Enum.reduce(to_replace, html, fn [str, file], acc ->
            case File.read(file) do
                {:ok, content} -> String.replace(acc, str, content)
                {:error, reason} ->
                    Logger.error("Can't read #{file} wile compiling html file. Reason : #{inspect reason}")
                    String.replace(acc, str, "")
            end
        end)
    end
end