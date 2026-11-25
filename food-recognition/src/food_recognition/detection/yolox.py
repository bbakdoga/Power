"""YOLOX-Tiny written from the YOLOX paper (Ge et al., 2021, arXiv:2107.08430).

Layer sizes follow YOLOX-Tiny (depth 0.33, width 0.375, 416x416 input). The
head is anchor-free with a decoupled classification / box / objectness branch
per stride (8, 16, 32). Training uses SimOTA label assignment.

The model's forward pass in eval mode returns raw decoded predictions
[batch, anchors, 4 + 1 + num_classes] (cx, cy, w, h in input pixels, then
sigmoid objectness and class scores). NMS happens outside the network, which
keeps the Core ML export simple: Vision or Swift does the NMS on device.
"""

from __future__ import annotations

import math

import torch
import torch.nn.functional as F
from torch import nn


class BaseConv(nn.Module):
    def __init__(self, cin: int, cout: int, ksize: int, stride: int = 1) -> None:
        super().__init__()
        self.conv = nn.Conv2d(cin, cout, ksize, stride, (ksize - 1) // 2, bias=False)
        self.bn = nn.BatchNorm2d(cout, eps=1e-3, momentum=0.03)
        self.act = nn.SiLU(inplace=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.act(self.bn(self.conv(x)))


class Bottleneck(nn.Module):
    def __init__(self, cin: int, cout: int, shortcut: bool = True) -> None:
        super().__init__()
        self.conv1 = BaseConv(cin, cout, 1)
        self.conv2 = BaseConv(cout, cout, 3)
        self.add = shortcut and cin == cout

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = self.conv2(self.conv1(x))
        return x + y if self.add else y


class CSPLayer(nn.Module):
    def __init__(self, cin: int, cout: int, n: int = 1, shortcut: bool = True) -> None:
        super().__init__()
        hidden = cout // 2
        self.conv1 = BaseConv(cin, hidden, 1)
        self.conv2 = BaseConv(cin, hidden, 1)
        self.conv3 = BaseConv(2 * hidden, cout, 1)
        self.m = nn.Sequential(*[Bottleneck(hidden, hidden, shortcut) for _ in range(n)])

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.conv3(torch.cat([self.m(self.conv1(x)), self.conv2(x)], dim=1))


class SPPBottleneck(nn.Module):
    def __init__(self, cin: int, cout: int, kernels: tuple[int, ...] = (5, 9, 13)) -> None:
        super().__init__()
        hidden = cin // 2
        self.conv1 = BaseConv(cin, hidden, 1)
        self.pools = nn.ModuleList([nn.MaxPool2d(k, 1, k // 2) for k in kernels])
        self.conv2 = BaseConv(hidden * (len(kernels) + 1), cout, 1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.conv1(x)
        return self.conv2(torch.cat([x] + [p(x) for p in self.pools], dim=1))


class Focus(nn.Module):
    """Space-to-depth stem. Written with strided slices, which Core ML converts cleanly."""

    def __init__(self, cin: int, cout: int) -> None:
        super().__init__()
        self.conv = BaseConv(cin * 4, cout, 3)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.conv(torch.cat([x[..., ::2, ::2], x[..., 1::2, ::2], x[..., ::2, 1::2], x[..., 1::2, 1::2]], dim=1))


class CSPDarknet(nn.Module):
    def __init__(self, depth: float, width: float) -> None:
        super().__init__()
        c = int(64 * width)
        d = max(round(3 * depth), 1)
        self.stem = Focus(3, c)
        self.dark2 = nn.Sequential(BaseConv(c, c * 2, 3, 2), CSPLayer(c * 2, c * 2, d))
        self.dark3 = nn.Sequential(BaseConv(c * 2, c * 4, 3, 2), CSPLayer(c * 4, c * 4, d * 3))
        self.dark4 = nn.Sequential(BaseConv(c * 4, c * 8, 3, 2), CSPLayer(c * 8, c * 8, d * 3))
        self.dark5 = nn.Sequential(BaseConv(c * 8, c * 16, 3, 2), SPPBottleneck(c * 16, c * 16),
                                   CSPLayer(c * 16, c * 16, d, shortcut=False))
        self.out_channels = (c * 4, c * 8, c * 16)

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        x = self.dark2(self.stem(x))
        c3 = self.dark3(x)
        c4 = self.dark4(c3)
        return c3, c4, self.dark5(c4)


class PAFPN(nn.Module):
    def __init__(self, depth: float, width: float) -> None:
        super().__init__()
        self.backbone = CSPDarknet(depth, width)
        c3, c4, c5 = self.backbone.out_channels
        n = round(3 * depth)
        self.lateral_conv0 = BaseConv(c5, c4, 1)
        self.C3_p4 = CSPLayer(2 * c4, c4, n, False)
        self.reduce_conv1 = BaseConv(c4, c3, 1)
        self.C3_p3 = CSPLayer(2 * c3, c3, n, False)
        self.bu_conv2 = BaseConv(c3, c3, 3, 2)
        self.C3_n3 = CSPLayer(2 * c3, c4, n, False)
        self.bu_conv1 = BaseConv(c4, c4, 3, 2)
        self.C3_n4 = CSPLayer(2 * c4, c5, n, False)
        self.out_channels = (c3, c4, c5)

    def forward(self, x: torch.Tensor) -> list[torch.Tensor]:
        x2, x1, x0 = self.backbone(x)
        fpn_out0 = self.lateral_conv0(x0)
        f_out0 = self.C3_p4(torch.cat([F.interpolate(fpn_out0, scale_factor=2.0, mode="nearest"), x1], 1))
        fpn_out1 = self.reduce_conv1(f_out0)
        pan_out2 = self.C3_p3(torch.cat([F.interpolate(fpn_out1, scale_factor=2.0, mode="nearest"), x2], 1))
        pan_out1 = self.C3_n3(torch.cat([self.bu_conv2(pan_out2), fpn_out1], 1))
        pan_out0 = self.C3_n4(torch.cat([self.bu_conv1(pan_out1), fpn_out0], 1))
        return [pan_out2, pan_out1, pan_out0]


class YOLOXHead(nn.Module):
    def __init__(self, num_classes: int, width: float, in_channels: tuple[int, ...],
                 strides: tuple[int, ...] = (8, 16, 32)) -> None:
        super().__init__()
        hidden = int(256 * width)
        self.num_classes, self.strides = num_classes, strides
        self.stems = nn.ModuleList([BaseConv(c, hidden, 1) for c in in_channels])
        self.cls_convs = nn.ModuleList([nn.Sequential(BaseConv(hidden, hidden, 3), BaseConv(hidden, hidden, 3)) for _ in strides])
        self.reg_convs = nn.ModuleList([nn.Sequential(BaseConv(hidden, hidden, 3), BaseConv(hidden, hidden, 3)) for _ in strides])
        self.cls_preds = nn.ModuleList([nn.Conv2d(hidden, num_classes, 1) for _ in strides])
        self.reg_preds = nn.ModuleList([nn.Conv2d(hidden, 4, 1) for _ in strides])
        self.obj_preds = nn.ModuleList([nn.Conv2d(hidden, 1, 1) for _ in strides])
        prior = -math.log((1 - 0.01) / 0.01)
        for conv in [*self.cls_preds, *self.obj_preds]:
            nn.init.constant_(conv.bias, prior)

    def forward(self, features: list[torch.Tensor]) -> tuple[torch.Tensor, torch.Tensor]:
        """Returns raw outputs [B, A, 4 + 1 + C] and the grid [A, 3] = (x, y, stride)."""
        outputs, grids = [], []
        for i, x in enumerate(features):
            x = self.stems[i](x)
            cls = self.cls_preds[i](self.cls_convs[i](x))
            reg_feat = self.reg_convs[i](x)
            out = torch.cat([self.reg_preds[i](reg_feat), self.obj_preds[i](reg_feat), cls], dim=1)
            b, ch, h, w = out.shape
            outputs.append(out.permute(0, 2, 3, 1).reshape(b, h * w, ch))
            ys, xs = torch.meshgrid(torch.arange(h, device=x.device), torch.arange(w, device=x.device), indexing="ij")
            grids.append(torch.stack([xs.reshape(-1), ys.reshape(-1), torch.full((h * w,), self.strides[i], device=x.device)], 1))
        return torch.cat(outputs, 1), torch.cat(grids, 0).float()


def decode(raw: torch.Tensor, grid: torch.Tensor) -> torch.Tensor:
    """Raw head output -> (cx, cy, w, h) in input pixels + sigmoid scores."""
    stride = grid[:, 2:3]
    xy = (raw[..., :2] + grid[:, :2]) * stride
    wh = torch.exp(raw[..., 2:4].clamp(max=10.0)) * stride
    return torch.cat([xy, wh, raw[..., 4:].sigmoid()], dim=-1)


class YOLOX(nn.Module):
    def __init__(self, num_classes: int = 1, depth: float = 0.33, width: float = 0.375) -> None:
        super().__init__()
        self.neck = PAFPN(depth, width)
        self.head = YOLOXHead(num_classes, width, self.neck.out_channels)

    @property
    def backbone(self) -> CSPDarknet:
        return self.neck.backbone

    def forward(self, x: torch.Tensor) -> torch.Tensor | tuple[torch.Tensor, torch.Tensor]:
        raw, grid = self.head(self.neck(x))
        if self.training:
            return raw, grid
        return decode(raw, grid)


SIZES = {"yolox_nano_like": (0.33, 0.25), "yolox_tiny": (0.33, 0.375), "yolox_s": (0.33, 0.50)}


def build(architecture: str, num_classes: int) -> YOLOX:
    if architecture not in SIZES:
        raise ValueError(f"unknown detector architecture {architecture}; choose from {sorted(SIZES)}")
    depth, width = SIZES[architecture]
    return YOLOX(num_classes, depth, width)
