#!/usr/bin/env python3
"""Export a numerical reference for the Swift Mage-VL port from stock mlx-vlm.

Builds the exact first-step prompt Microsoft's reference harness (MAGEHybridAgent) sends,
renders it with the checkpoint's own chat template, preprocesses the screenshot with
mlx-vlm's processor, and records the intermediate tensors the Swift side compares against.

    python -m venv .venv && .venv/bin/pip install "mlx-vlm==0.7.11"
    .venv/bin/python scripts/parity/export_reference.py \
        --model ~/Library/Application\\ Support/Do/Models/pratikgx/Mage-VL-Cowork-MLX-4bit \
        --image screenshot.png --task "Switch the system appearance to Dark mode." --out ref/

Then: mage-cli parity --model <model> --ref ref/
"""

import argparse
import os
import shutil

import mlx.core as mx
from mlx_vlm import load
from PIL import Image

MAC_NOTE = (
    "This computer is a Mac running macOS. Use the Command (cmd) key for keyboard shortcuts, "
    "and note the shell is zsh with macOS (BSD) command-line tools."
)


def system_prompt(path: str) -> str:
    # The verbatim MAGE_HYBRID_SYSTEM_PROMPT, extracted from the Swift source of truth.
    src = open(path, encoding="utf-8").read()
    start = src.index('#"""\n') + len('#"""\n')
    end = src.index('\n"""#')
    return src[start:end]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--image", required=True)
    ap.add_argument("--task", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--no-mac-note", action="store_true")
    ap.add_argument(
        "--system-prompt-swift",
        default=os.path.join(
            os.path.dirname(__file__), "../../Packages/DoKit/Sources/DoCore/Agent/MageSystemPrompt.swift"
        ),
    )
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    instruction = args.task if args.no_mac_note else f"{args.task}\n\n({MAC_NOTE})"
    context = (
        "Please generate the next move according to the UI screenshot, instruction and previous actions."
        f"\n\nInstruction: {instruction}\n\nPrevious actions:\nNone"
    )
    messages = [
        {"role": "system", "content": [{"type": "text", "text": system_prompt(args.system_prompt_swift)}]},
        {"role": "user", "content": [{"type": "image"}, {"type": "text", "text": "\n" + context}]},
    ]

    model, processor = load(args.model)
    prompt = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    image = Image.open(args.image).convert("RGB")
    inputs = processor(text=[prompt], images=[image], return_tensors="np")

    input_ids = mx.array(inputs["input_ids"]).astype(mx.int32)
    pixel_values = mx.array(inputs["pixel_values"]).astype(mx.float32)
    grid = mx.array(inputs["image_grid_thw"]).astype(mx.int32)

    grid_list = [tuple(int(v) for v in row) for row in grid.tolist()]
    from mlx_vlm.models.mage_vl.mage_vl import _positions_from_grid

    positions = _positions_from_grid(grid_list, model.config.vision_config)
    dtype = model.language_model.model.embed_tokens(input_ids[:, :1]).dtype
    vision = model.vision_tower(pixel_values.astype(dtype), positions, grid_list)

    features = model.get_input_embeddings(
        input_ids, pixel_values, image_grid_thw=grid
    ).inputs_embeds
    logits = model.language_model(inputs=input_ids, inputs_embeds=features).logits
    mx.eval(vision, logits)

    mx.save_safetensors(
        os.path.join(args.out, "reference.safetensors"),
        {
            "input_ids": input_ids,
            "pixel_values": pixel_values,
            "image_grid_thw": grid,
            "vision_features": vision.astype(mx.float32),
            "logits_last": logits[0, -1].astype(mx.float32),
        },
    )
    with open(os.path.join(args.out, "prompt.txt"), "w", encoding="utf-8") as f:
        f.write(prompt)
    with open(os.path.join(args.out, "task.txt"), "w", encoding="utf-8") as f:
        f.write(instruction)
    shutil.copy(args.image, os.path.join(args.out, "screenshot.png"))
    top = mx.argsort(-logits[0, -1])[:5].tolist()
    print(f"tokens={input_ids.shape[1]} grid={grid_list} vision={vision.shape} top5={top}")


if __name__ == "__main__":
    main()
