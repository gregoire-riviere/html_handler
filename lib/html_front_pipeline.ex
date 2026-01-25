defmodule Mix.Tasks.CompileFront do
  use Mix.Task
  @requirements ["app.config"]

  def run(_) do
    directories = Application.get_env(:html_handler, :directories) || %{}
    js_directory = directories[:js]
    html_directory = directories[:html]
    css_directory = directories[:css]
    dir_to_copy = directories[:dir_to_copy]
    output = directories[:output]
    templatization? = Application.get_env(:html_handler, :templatization?, false)
    watch? = Application.get_env(:html_handler, :watch?, false)

    compile_front(
      js_directory,
      html_directory,
      css_directory,
      dir_to_copy,
      output,
      templatization?
    )

    if watch? do
      watch_dirs =
        [html_directory, css_directory, js_directory]
        |> Enum.concat(List.wrap(dir_to_copy))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Path.expand/1)
        |> Enum.filter(&File.dir?/1)
        |> Enum.uniq()

      if watch_dirs == [] do
        Mix.shell().info("No directories to watch. Exiting.")
      else
        Mix.shell().info("Watching for changes... (Ctrl+C to stop)")

        watch_loop(watch_dirs, output, fn ->
          compile_front(
            js_directory,
            html_directory,
            css_directory,
            dir_to_copy,
            output,
            templatization?
          )
        end)
      end
    end
  end

  defp compile_front(
         js_directory,
         html_directory,
         css_directory,
         dir_to_copy,
         output,
         templatization?
       ) do
    previous_output =
      output
      |> String.replace_suffix("/", "")

    previous_output = previous_output <> ".previous/"
    File.rm_rf!(previous_output)
    File.rename(output, previous_output)
    File.mkdir(output)

    File.mkdir(output <> "/html")
    File.mkdir(output <> "/css")
    File.mkdir(output <> "/js")

    IO.puts(" --- HTML ---")

    File.ls!(html_directory)
    |> Enum.filter(&String.ends_with?(&1, ".html"))
    |> Enum.each(fn origin ->
      IO.puts("#{html_directory}/#{origin}")

      tempo =
        if templatization? do
          File.read!("#{html_directory}/#{origin}")
          |> HTMLHandler.Templater.replace(html_directory)
        else
          File.read!("#{html_directory}/#{origin}")
        end

      File.write!("#{output}/html/temp.#{origin}", tempo)

      :os.cmd(
        ~c"npx html-minifier --collapse-whitespace --remove-comments --remove-redundant-attributes #{output}/html/temp.#{origin} > #{output}/html/#{origin}"
      )

      File.rm("#{output}/html/temp.#{origin}")
    end)

    if File.exists?(css_directory) do
      IO.puts(" --- CSS ---")

      File.ls!(css_directory)
      |> Enum.filter(&String.ends_with?(&1, ".css"))
      |> Enum.each(fn origin ->
        IO.puts("#{css_directory}/#{origin}")
        :os.cmd(~c"npx minify #{css_directory}/#{origin} > #{output}/css/#{origin}")
      end)
    end

    if File.exists?(js_directory) do
      IO.puts(" --- JS ---")

      File.ls!(js_directory)
      |> Enum.filter(&String.ends_with?(&1, ".js"))
      |> Enum.each(fn origin ->
        IO.puts("#{js_directory}/#{origin}")
        :os.cmd(~c"npx uglify-js #{js_directory}/#{origin} > #{output}/js/#{origin}")
      end)
    end

    if dir_to_copy do
      dir_to_copy
      |> Enum.each(fn d ->
        name = Path.basename(d)
        File.mkdir("#{output}/#{name}")
        File.cp_r(d, "#{output}/#{name}")
      end)
    end
  end

  defp watch_loop(dirs, output, compile_fun) do
    {:ok, pid} = FileSystem.start_link(dirs: dirs)
    FileSystem.subscribe(pid)

    loop(%{
      watcher_pid: pid,
      output: output,
      pending?: false,
      compile_fun: compile_fun
    })
  end

  defp loop(state) do
    receive do
      {:file_event, watcher_pid, {path, _events}} when watcher_pid == state.watcher_pid ->
        if ignore_path?(path, state.output) do
          loop(state)
        else
          Mix.shell().info("Change detected: #{path}")
          loop(schedule_compile(state))
        end

      {:file_event, watcher_pid, :stop} when watcher_pid == state.watcher_pid ->
        Mix.shell().info("File watcher stopped.")
        :ok

      :compile ->
        state.compile_fun.()
        loop(%{state | pending?: false})
    end
  end

  defp schedule_compile(%{pending?: true} = state), do: state

  defp schedule_compile(state) do
    Process.send_after(self(), :compile, 200)
    %{state | pending?: true}
  end

  defp ignore_path?(_path, nil), do: false

  defp ignore_path?(path, output) do
    output = Path.expand(output)
    output_prefix = Path.join(output, "")
    expanded_path = Path.expand(path)
    expanded_path == output or String.starts_with?(expanded_path, output_prefix)
  end
end

defmodule Mix.Tasks.InstallMinifiers do
  use Mix.Task

  def run(_) do
    :os.cmd(~c"npm install -g uglifyjs")
    :os.cmd(~c"npm install -g minify")
    :os.cmd(~c"npm install -g html-minifier")
  end
end
