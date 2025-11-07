cask "aagedal-video-loop-converter" do
  version "2.6.1"
  sha256 :no_check

  url "https://github.com/aagedal/Aagedal-VideoLoop-Converter/releases/download/v.#{version}/AagedalVideoLoop_Converter_#{version.tr(".", "-")}.zip",
      verified: "github.com/aagedal/Aagedal-VideoLoop-Converter/"
  name "Aagedal VideoLoop Converter"
  desc "Convert videos into looping clips using bundled FFmpeg"
  homepage "https://github.com/aagedal/Aagedal-VideoLoop-Converter"

  depends_on macos: ">= :sonoma"

  app "Aagedal VideoLoop Converter 2.0.app"

  caveats do
    <<~EOS
      Replace the placeholder checksum before distributing this cask.
      Generate the SHA-256 with:
        shasum -a 256 AagedalVideoLoop_Converter_#{version.tr(".", "-")}.zip
    EOS
  end
end