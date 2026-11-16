#!/usr/bin/env python3
"""Convert a Hugging Face wav2vec2 CTC model into a Core ML word aligner package.

The app aligns Whisper words against these models' character emissions. The
script is run by hand when adding or refreshing an aligner; the app downloads
the zipped result at runtime. It needs PyTorch, transformers and coremltools,
for example:

    uv run --python 3.12 --with 'torch==2.7.0' --with 'transformers<5' \\
        --with 'coremltools==9.0' --with numpy \\
        scripts/convert-wav2vec2-coreml.py NbAiLab/nb-wav2vec2-300m-bokmaal-v2 \\
        --id nb-bokmaal-300m --languages no,nb --output build/aligners

It writes two aligners, each a folder with `Wav2Vec2CTC.mlpackage` and
`aligner.json` plus a zip of it, and prints each zip's size and SHA-256 for
`WordAlignerModel.allModels`:

- `<id>.zip` stores weights as 8-bit integers, about half the size. On five
  minutes of speech every character stayed within one 20 ms frame of the
  float16 model; 6- and 4-bit weights moved some by 0.4 s or more.
- `<id>-float16.zip` keeps the weights at the computation precision.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from huggingface_hub import HfApi
from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor

SAMPLE_RATE = 16_000
# Long enough for any alignment window the app builds (it caps them at 30 s).
MAXIMUM_SECONDS = 40


class LogProbabilities(torch.nn.Module):
    """Returns per-frame log probabilities; audio is normalised by the caller."""

    def __init__(self, model: Wav2Vec2ForCTC):
        super().__init__()
        self.model = model

    def forward(self, audio: torch.Tensor) -> torch.Tensor:
        logits = self.model(audio).logits
        return torch.log_softmax(logits, dim=-1)


def normalise(audio: np.ndarray) -> np.ndarray:
    return (audio - audio.mean()) / np.sqrt(audio.var() + 1e-7)


def convert(arguments: argparse.Namespace) -> None:
    processor = Wav2Vec2Processor.from_pretrained(arguments.repository, revision=arguments.revision)
    model = Wav2Vec2ForCTC.from_pretrained(
        arguments.repository, revision=arguments.revision, attn_implementation="eager"
    ).eval()
    wrapper = LogProbabilities(model).eval()

    rng = np.random.default_rng(7)
    example = normalise(rng.standard_normal(SAMPLE_RATE * 8).astype(np.float32) * 0.1)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, torch.from_numpy(example)[None])

    samples = ct.RangeDim(lower_bound=SAMPLE_RATE // 2, upper_bound=SAMPLE_RATE * MAXIMUM_SECONDS,
                          default=SAMPLE_RATE * 8)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=(1, samples), dtype=np.float32)],
        outputs=[ct.TensorType(name="log_probabilities", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16 if arguments.precision == "float16" else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
    )
    mlmodel.short_description = f"wav2vec2 CTC log probabilities from {arguments.repository}"
    quantized = cto.linear_quantize_weights(mlmodel, cto.OptimizationConfig(
        global_config=cto.OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8", granularity="per_channel")))
    variants = {arguments.id: quantized, f"{arguments.id}-{arguments.precision}": mlmodel}

    # Compare against PyTorch at lengths other than the traced one.
    for seconds in (3, 17):
        audio = normalise(rng.standard_normal(SAMPLE_RATE * seconds).astype(np.float32) * 0.1)
        with torch.no_grad():
            reference = wrapper(torch.from_numpy(audio)[None]).numpy()
        for name, variant in variants.items():
            predicted = variant.predict({"audio": audio[None]})["log_probabilities"]
            if predicted.shape != reference.shape:
                raise SystemExit(f"{name}: shape mismatch at {seconds}s: {predicted.shape} vs {reference.shape}")
            agreement = (predicted.argmax(-1) == reference.argmax(-1)).mean()
            print(f"{name} {seconds:>2}s: frames={reference.shape[1]} "
                  f"max|Δ|={np.abs(predicted - reference).max():.3f} argmax agreement={agreement:.3f}")

    tokenizer = processor.tokenizer
    vocabulary = tokenizer.get_vocab()
    revision = arguments.revision or HfApi().model_info(arguments.repository).sha
    manifest = {
        "format": 1,
        "id": arguments.id,
        "sourceRepository": arguments.repository,
        "sourceRevision": revision,
        "license": arguments.license,
        "languages": arguments.languages.split(","),
        "sampleRate": SAMPLE_RATE,
        "maximumSeconds": MAXIMUM_SECONDS,
        "normalizeAudio": bool(processor.feature_extractor.do_normalize),
        "blankTokenID": tokenizer.pad_token_id,
        "wordDelimiter": tokenizer.word_delimiter_token,
        "lowercase": not any(token.isupper() for token in vocabulary if len(token) == 1),
        "vocabulary": vocabulary,
    }
    for name, variant in variants.items():
        destination = Path(arguments.output) / name
        if destination.exists():
            shutil.rmtree(destination)
        destination.mkdir(parents=True)
        variant.save(str(destination / "Wav2Vec2CTC.mlpackage"))
        (destination / "aligner.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

        archive = Path(arguments.output) / f"{name}.zip"
        archive.unlink(missing_ok=True)
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(destination), str(archive)], check=True)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        print(f"{archive} {archive.stat().st_size} bytes sha256={digest}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("repository", help="Hugging Face repository of a Wav2Vec2ForCTC model")
    parser.add_argument("--id", required=True, help="Aligner identifier used by the app")
    parser.add_argument("--languages", required=True, help="Comma-separated Whisper language codes")
    parser.add_argument("--license", default="apache-2.0")
    parser.add_argument("--revision", help="Pinned repository revision (default: current main)")
    parser.add_argument("--precision", choices=["float16", "float32"], default="float16",
                        help="Precision of the computation")
    parser.add_argument("--output", default="build/aligners")
    convert(parser.parse_args())


if __name__ == "__main__":
    main()
