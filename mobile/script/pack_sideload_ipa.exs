# Device IPA with an ad-hoc signature and no provisioning profile.
# Sideload tools replace the signature. This does not change TestFlight signing.
#
# Run from mobile/:
#   mix run --no-start script/pack_sideload_ipa.exs

mobile = Path.expand("..", __DIR__)
File.cd!(mobile)

HandbeamProbe.IosMarkdownRelease.install!()

driver = Path.join(mobile, "priv/generated/driver_tab_ios.c")
File.exists?(driver) || Mix.raise("missing #{driver}")

{:ok, otp_root} = MobDev.OtpDownloader.ensure_ios_device()
cfg = MobDev.NativeBuild.__load_config__()
elixir_lib = cfg[:elixir_lib]
bundle_id = cfg[:bundle_id]
app_module = Mix.Project.config()[:app] |> Atom.to_string()
app_name = Macro.camelize(app_module)

script =
  MobDev.Release.release_device_sh()
  |> String.replace(
    ~S[cd "$(dirname "$0")/.."],
    "cd \"#{mobile}\"",
    global: false
  )

start = ~S(echo "=== Embedding App Store provisioning profile ===")
finish = ~S(codesign --verify --deep --strict --verbose=2 "$APP")

replacement = """
echo "=== Ad-hoc signature (re-signable, no provisioning profile) ==="
rm -f "$APP/embedded.mobileprovision"
codesign --force --sign - --timestamp=none "$APP"
echo "=== Verifying ad-hoc signature ==="
codesign --verify --verbose=2 "$APP"
"""

script =
  case String.split(script, start, parts: 2) do
    [head, rest] ->
      case String.split(rest, finish, parts: 2) do
        [_dropped, tail] -> head <> String.trim_trailing(replacement) <> tail
        _ -> Mix.raise("could not find the distribution codesign anchor")
      end

    _ ->
      Mix.raise("could not find the App Store provisioning profile anchor")
  end

if String.contains?(script, "Embedding App Store provisioning profile") do
  Mix.raise("App Store profile step is still in the sideload script")
end

unless String.contains?(script, "Ad-hoc signature") do
  Mix.raise("ad-hoc signing patch did not apply")
end

script_path = Path.join(System.tmp_dir!(), "handbeam-sideload-release.sh")
File.write!(script_path, script)
File.chmod!(script_path, 0o755)

output_dir = System.get_env("HANDBEAM_IPA_DIR") || Path.join(mobile, "artifacts")
File.mkdir_p!(output_dir)

plugin_env = MobDev.Release.plugin_ios_build_env(MobDev.Plugin.activated())
{shot_key, shot_val} = MobDev.Release.screenshot_build_env(cfg)

extra =
  [
    {"MOB_DIR", Path.expand(cfg[:mob_dir])},
    {"MOB_ELIXIR_LIB", Path.expand(elixir_lib)},
    {"MOB_IOS_DEVICE_OTP_ROOT", otp_root},
    {"MOB_IOS_EPMD_BUILD_SRC", otp_root},
    {"MOB_IOS_BUNDLE_ID", bundle_id},
    {"MOB_IOS_TEAM_ID", "ADHOC00000"},
    {"MOB_IOS_SIGN_IDENTITY", "-"},
    {"MOB_IOS_PROFILE_UUID", "adhoc"},
    {"MOB_APP_NAME", app_name},
    {"MOB_APP_MODULE", app_module},
    {"MOB_RELEASE_OUTPUT_DIR", output_dir},
    {"MOB_SLIM", "1"},
    {shot_key, shot_val}
  ] ++ plugin_env

env = System.get_env() |> Map.merge(Map.new(extra)) |> Map.to_list()

IO.puts("bundle_id=#{bundle_id}")
IO.puts("otp_root=#{otp_root}")
IO.puts("output_dir=#{output_dir}")

case System.cmd("bash", [script_path], env: env, stderr_to_stdout: true, into: IO.stream()) do
  {_, 0} ->
    built = Path.join(output_dir, "#{app_name}.ipa")
    dest = Path.join(output_dir, "Handbeam-ios-sideload.ipa")

    if built != dest do
      File.rm(dest)
      File.rename!(built, dest)
    end

    IO.puts("SIDELOAD_IPA #{dest}")

  {_, code} ->
    System.halt(code)
end
