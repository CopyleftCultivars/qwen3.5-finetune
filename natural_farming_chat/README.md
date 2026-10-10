# Natural Farming Chat

Flutter application using the local Cactus plugin in `packages/cactus`.

## Android flavors

The `production` flavor keeps the existing application ID and Qwen3 model.
The `qwen35` flavor installs side by side as
`com.copyleftcultivars.natural_farming_chat.qwen35` and uses the finetuned
Qwen3.5-2B bundle.

For local Qwen3.5 development, stage the converted bundle on the device and run
that flavor:

```sh
adb push ../outputs/qwen35-combined-cactus-cq4/. /data/local/tmp/qwen35-combined-cq4/
flutter run --flavor qwen35 -d <device-id>
```

On first launch, ModelService copies the staged bundle into the app's private
model directory. The production flavor retains its existing Hugging Face
bundle download. The Qwen3.5 flavor also skips the second embedding-model
context and exposes the full local tool list.

Build the production Android app with:

```sh
flutter build apk --release --flavor production
```

Build an Apple target with `flutter build ios --release` or
`flutter build macos --release`.
