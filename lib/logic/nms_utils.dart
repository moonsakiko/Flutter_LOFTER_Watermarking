import 'dart:ui'; // 👈 关键修复：引入UI库以支持 Rect
import 'dart:math';

/// 边界框数据模型
class Detection {
  final Rect box;      // 位置 (x, y, w, h)
  final double score;  // 置信度
  final int classIndex;// 类别

  Detection(this.box, this.score, this.classIndex);
}

/// 非极大值抑制 (NMS) - 去除重叠框
List<Detection> nonMaxSuppression(List<Detection> detections, double iouThreshold) {
  if (detections.isEmpty) return [];

  // 按分数降序排列
  detections.sort((a, b) => b.score.compareTo(a.score));

  List<Detection> selected = [];
  List<bool> active = List.filled(detections.length, true);

  for (int i = 0; i < detections.length; i++) {
    if (active[i]) {
      selected.add(detections[i]);
      for (int j = i + 1; j < detections.length; j++) {
        if (active[j]) {
          double iou = computeIoU(detections[i].box, detections[j].box);
          if (iou > iouThreshold) {
            active[j] = false; // 抑制重叠过高的框
          }
        }
      }
    }
  }
  return selected;
}

/// 计算两个框的交并比 (IoU)
double computeIoU(Rect box1, Rect box2) {
  final intersection = box1.intersect(box2);
  // 如果没有交集，intersect 可能返回负宽高的矩形
  if (intersection.width <= 0 || intersection.height <= 0) return 0.0;

  final unionArea = (box1.width * box1.height) + 
                    (box2.width * box2.height) - 
                    (intersection.width * intersection.height);
                    
  if (unionArea <= 0) return 0.0;
  
  return (intersection.width * intersection.height) / unionArea;
}