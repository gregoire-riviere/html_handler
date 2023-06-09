defmodule Mix.Tasks.CompileFront do

  use Mix.Task
  @requirements ["app.config"]

  def run(_) do
    js_directory = Application.get_env(:html_handler, :directories)[:js]
    html_directory = Application.get_env(:html_handler, :directories)[:html]
    css_directory = Application.get_env(:html_handler, :directories)[:css]
    dir_to_copy = Application.get_env(:html_handler, :directories)[:dir_to_copy]
    output = Application.get_env(:html_handler, :directories)[:output]
    templatization? = Application.get_env(:html_handler, :templatization?, false)
    
    previous_output = output |>
    String.replace_suffix("/", "")
    previous_output = previous_output <> ".previous/"
    File.rm_rf!(previous_output)
    File.rename(output, previous_output)
    File.mkdir(output)

    File.mkdir(output <> "/html")
    File.mkdir(output <> "/css")
    File.mkdir(output <> "/js")

    IO.puts(" --- HTML ---")
    File.ls!(html_directory) |>
    Enum.filter(& String.ends_with?(&1, ".html")) |>
    Enum.each(fn origin ->
        IO.puts("#{html_directory}/#{origin}")
        tempo = if templatization? do 
            File.read!("#{html_directory}/#{origin}") |> HTMLHandler.Templater.replace(html_directory)
        else File.read!("#{html_directory}/#{origin}") end
        File.write!("#{output}/html/temp.#{origin}", tempo)
        :os.cmd('minify #{output}/html/temp.#{origin} > #{output}/html/#{origin}')
        File.rm("#{output}/html/temp.#{origin}")
    end)

    IO.puts(" --- JS ---")
    File.ls!(css_directory) |>
    Enum.filter(& String.ends_with?(&1, ".css")) |>
    Enum.each(fn origin ->
        IO.puts("#{css_directory}/#{origin}")
        :os.cmd('minify #{css_directory}/#{origin} > #{output}/css/#{origin}')
    end)

    IO.puts(" --- CSS ---")
    File.ls!(js_directory) |>
    Enum.filter(& String.ends_with?(&1, ".js")) |>
    Enum.each(fn origin ->
        IO.puts("#{js_directory}/#{origin}")
        :os.cmd('uglifyjs #{js_directory}/#{origin} > #{output}/js/#{origin}')
    end)

    if dir_to_copy do
        dir_to_copy |> Enum.each(fn d ->
            name = Path.basename(d)
            File.mkdir("#{output}/#{name}")
            File.cp_r(d, "#{output}/#{name}")
        end)
    end

  end
end