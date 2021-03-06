defmodule Bob.Job.DockerChecker do
  @erlang_build_regex ~r"^OTP-(\d+(?:\.\d+)?(?:\.\d+))?$"
  @erlang_tag_regex ~r"^((\d+)(?:\.\d+)?(?:\.\d+)?)-([^-]+)-(.+)$"
  @elixir_build_regex ~r"^v(\d+\.\d+\.\d+)-otp-(\d+)$"
  @elixir_tag_regex ~r"^(.+)-erlang-(.+)-([^-]+)-(.+)$"

  @builds %{
    "alpine-3.10" => %{"alpine" => ["3.11.2", "3.11.3"]},
    "ubuntu-14.04" => %{"ubuntu" => ["bionic-20200219"]}
  }

  def run([]) do
    erlang()
    elixir()
  end

  defp erlang() do
    tags = erlang_tags()

    expected_tags =
      for {build, operating_systems} <- @builds,
          ref <- erlang_refs(build),
          {operating_system, versions} <- operating_systems,
          version <- versions,
          do: {ref, operating_system, version}

    Enum.each(expected_tags -- tags, fn {ref, os, os_version} ->
      # Skip for now while we are testing
      unless os == "ubuntu" do
        Bob.Queue.run(Bob.Job.BuildDockerErlang, [ref, os, os_version])
      end
    end)
  end

  defp erlang_refs(build) do
    "builds/otp/#{build}"
    |> Bob.Repo.fetch_built_refs()
    |> Map.keys()
    |> Enum.map(&parse_erlang_build/1)
    |> Enum.filter(& &1)
  end

  defp erlang_tags() do
    "hexpm/erlang"
    |> Bob.DockerHub.fetch_repo_tags()
    |> Enum.map(&parse_erlang_tag/1)
    |> Enum.map(fn {erlang, _major, os, os_version} -> {erlang, os, os_version} end)
  end

  defp parse_erlang_build(build) do
    case Regex.run(@erlang_build_regex, build, capture: :all_but_first) do
      [version] -> version
      nil -> nil
    end
  end

  defp elixir() do
    erlang_tags = Bob.DockerHub.fetch_repo_tags("hexpm/erlang")
    elixir_builds = Map.keys(Bob.Repo.fetch_built_refs("builds/elixir"))
    tags = Bob.DockerHub.fetch_repo_tags("hexpm/elixir")

    builds =
      for elixir_build <- elixir_builds,
          build_elixir?(elixir_build),
          {elixir, elixir_erlang_major} = parse_elixir_build(elixir_build),
          erlang_tag <- erlang_tags,
          {erlang, erlang_major, os, os_version} = parse_erlang_tag(erlang_tag),
          elixir_erlang_major == erlang_major,
          do: {elixir, erlang, erlang_major, os, os_version}

    Enum.each(diff_elixir_tags(builds, tags), fn {elixir, erlang, erlang_major, os, os_version} ->
      # Skip for now while we are testing
      unless os == "ubuntu" do
        Bob.Queue.run(Bob.Job.BuildDockerElixir, [elixir, erlang, erlang_major, os, os_version])
      end
    end)
  end

  defp build_elixir?(build) do
    Regex.match?(@elixir_build_regex, build)
  end

  defp parse_elixir_build(build) do
    [elixir, erlang_major] = Regex.run(@elixir_build_regex, build, capture: :all_but_first)
    {elixir, erlang_major}
  end

  defp parse_erlang_tag(tag) do
    [erlang, major, os, os_version] = Regex.run(@erlang_tag_regex, tag, capture: :all_but_first)
    {erlang, major, os, os_version}
  end

  defp diff_elixir_tags(builds, tags) do
    tags =
      MapSet.new(tags, fn tag ->
        [elixir, erlang, os, os_version] =
          Regex.run(@elixir_tag_regex, tag, capture: :all_but_first)

        {elixir, erlang, os, os_version}
      end)

    Enum.reject(builds, fn {elixir, erlang, _erlang_major, os, os_version} ->
      {elixir, erlang, os, os_version} in tags
    end)
  end

  def equal?(_, _), do: true

  def similar?(_, _), do: true
end
