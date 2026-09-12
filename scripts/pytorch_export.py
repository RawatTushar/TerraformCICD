import torch
from torchvision import models

model = models.resnet50(
    weights=models.ResNet50_Weights.IMAGENET1K_V1
).eval().to("cuda")

traced_model = torch.jit.trace(
    model,
    torch.randn(1, 3, 224, 224).to("cuda")
)

torch.jit.save(traced_model, "model.pt")