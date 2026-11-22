"""YOLOX loss with SimOTA label assignment (Ge et al., 2021, section 2.2)."""

from __future__ import annotations

import torch
import torch.nn.functional as F


def box_iou_cxcywh(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    """Pairwise IoU between [N, 4] and [M, 4] boxes in (cx, cy, w, h)."""
    a0, a1 = a[:, None, :2] - a[:, None, 2:] / 2, a[:, None, :2] + a[:, None, 2:] / 2
    b0, b1 = b[None, :, :2] - b[None, :, 2:] / 2, b[None, :, :2] + b[None, :, 2:] / 2
    inter = (torch.min(a1, b1) - torch.max(a0, b0)).clamp(min=0).prod(-1)
    return inter / (a[:, None, 2:].prod(-1) + b[None, :, 2:].prod(-1) - inter + 1e-9)


def aligned_iou(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    a0, a1 = a[:, :2] - a[:, 2:] / 2, a[:, :2] + a[:, 2:] / 2
    b0, b1 = b[:, :2] - b[:, 2:] / 2, b[:, :2] + b[:, 2:] / 2
    inter = (torch.min(a1, b1) - torch.max(a0, b0)).clamp(min=0).prod(-1)
    return inter / (a[:, 2:].prod(-1) + b[:, 2:].prod(-1) - inter + 1e-9)


class YOLOXLoss:
    def __init__(self, num_classes: int, center_radius: float = 2.5, iou_weight: float = 5.0) -> None:
        self.num_classes, self.center_radius, self.iou_weight = num_classes, center_radius, iou_weight

    def __call__(self, raw: torch.Tensor, grid: torch.Tensor, targets: list[torch.Tensor],
                 use_l1: bool = False) -> tuple[torch.Tensor, dict[str, float]]:
        """raw: [B, A, 5 + C]; targets: per image [N, 5] = (class, cx, cy, w, h) in input pixels."""
        raw = raw.float()
        stride = grid[:, 2]
        centers = (grid[:, :2] + 0.5) * stride[:, None]
        boxes = torch.cat([(raw[..., :2] + grid[:, :2]) * stride[:, None],
                           torch.exp(raw[..., 2:4].clamp(max=10.0)) * stride[:, None]], -1)
        obj_logits, cls_logits = raw[..., 4], raw[..., 5:]

        obj_targets = torch.zeros_like(obj_logits)
        fg_masks, cls_t, reg_t, l1_t = [], [], [], []
        num_fg = 0.0
        for b, gt in enumerate(targets):
            fg = torch.zeros(raw.shape[1], dtype=torch.bool, device=raw.device)
            if gt.numel() == 0:
                fg_masks.append(fg)
                continue
            gt = gt.to(raw.device).float()
            with torch.no_grad():
                matched_gt, pred_iou, fg = self._simota(boxes[b], cls_logits[b], obj_logits[b], gt, centers, stride)
            num_fg += float(fg.sum())
            fg_masks.append(fg)
            obj_targets[b, fg] = 1.0
            onehot = F.one_hot(gt[matched_gt, 0].long(), self.num_classes).float()
            cls_t.append(onehot * pred_iou[:, None])
            reg_t.append(gt[matched_gt, 1:5])
            if use_l1:
                g = grid[fg]
                l1_t.append(torch.cat([gt[matched_gt, 1:3] / g[:, 2:3] - g[:, :2],
                                       torch.log(gt[matched_gt, 3:5] / g[:, 2:3] + 1e-8)], 1))

        fg_all = torch.stack(fg_masks)
        num_fg = max(num_fg, 1.0)
        loss_obj = F.binary_cross_entropy_with_logits(obj_logits, obj_targets, reduction="sum") / num_fg
        if fg_all.any():
            iou = aligned_iou(boxes[fg_all], torch.cat(reg_t))
            loss_iou = (1 - iou ** 2).sum() / num_fg
            loss_cls = F.binary_cross_entropy_with_logits(cls_logits[fg_all], torch.cat(cls_t), reduction="sum") / num_fg
            loss_l1 = (F.l1_loss(raw[..., :4][fg_all], torch.cat(l1_t), reduction="sum") / num_fg
                       if use_l1 else raw.new_zeros(()))
        else:
            loss_iou = loss_cls = loss_l1 = raw.sum() * 0.0
        total = self.iou_weight * loss_iou + loss_obj + loss_cls + loss_l1
        return total, {"iou": float(loss_iou.detach()), "obj": float(loss_obj.detach()), "cls": float(loss_cls.detach()),
                       "l1": float(loss_l1.detach()), "fg": num_fg / max(len(targets), 1)}

    def _simota(self, boxes: torch.Tensor, cls_logits: torch.Tensor, obj_logits: torch.Tensor, gt: torch.Tensor,
                centers: torch.Tensor, stride: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        gt_xy, gt_wh = gt[:, 1:3], gt[:, 3:5]
        delta = centers[None] - gt_xy[:, None]                                # [G, A, 2]
        in_box = (delta.abs() < gt_wh[:, None] / 2).all(-1)
        radius = self.center_radius * stride[None, :, None]
        in_center = (delta.abs() < radius).all(-1)
        candidates = (in_box | in_center).any(0)                             # [A]
        both = (in_box & in_center)[:, candidates]                           # [G, Ac]

        cand_boxes = boxes[candidates]
        ious = box_iou_cxcywh(gt[:, 1:5], cand_boxes)                       # [G, Ac]
        scores = (cls_logits[candidates].sigmoid() * obj_logits[candidates, None].sigmoid()).sqrt()
        gt_onehot = F.one_hot(gt[:, 0].long(), self.num_classes).float()
        cls_cost = F.binary_cross_entropy(scores[None].expand(len(gt), -1, -1).clamp(1e-6, 1 - 1e-6),
                                          gt_onehot[:, None].expand(-1, scores.shape[0], -1), reduction="none").sum(-1)
        cost = cls_cost + 3.0 * -torch.log(ious + 1e-8) + 1e5 * (~both)

        matching = torch.zeros_like(cost, dtype=torch.bool)
        k = min(10, ious.shape[1])
        dynamic_k = torch.topk(ious, k, dim=1).values.sum(1).int().clamp(min=1)
        for g in range(len(gt)):
            idx = torch.topk(cost[g], min(int(dynamic_k[g]), cost.shape[1]), largest=False).indices
            matching[g, idx] = True
        multiple = matching.sum(0) > 1
        if multiple.any():
            best = cost[:, multiple].argmin(0)
            matching[:, multiple] = False
            matching[best, multiple.nonzero().squeeze(1)] = True
        fg_cand = matching.any(0)
        matched_gt = matching[:, fg_cand].int().argmax(0)
        pred_iou = (matching.float() * ious).sum(0)[fg_cand]

        fg = torch.zeros_like(candidates)
        fg[candidates.nonzero().squeeze(1)[fg_cand]] = True
        return matched_gt, pred_iou, fg
