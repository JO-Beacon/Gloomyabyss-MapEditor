import 'package:flutter/widgets.dart';
import 'package:jo_draftui/jo_draftui.dart';

/// 新建段：名字、尺寸、origin。
class NewSegmentDialog extends StatefulWidget {
  const NewSegmentDialog({
    super.key,
    required this.onCancel,
    required this.onCreate,
  });

  final VoidCallback onCancel;
  final void Function(String name, int width, int height, int col, int row)
      onCreate;

  @override
  State<NewSegmentDialog> createState() => _NewSegmentDialogState();
}

class _NewSegmentDialogState extends State<NewSegmentDialog> {
  String _name = '';
  int _width = 16;
  int _height = 16;
  int _col = 0;
  int _row = 0;

  @override
  Widget build(BuildContext context) {
    final p = JoTheme.of(context);

    Widget num(String label, int value, ValueChanged<int> onChanged) {
      return Padding(
        padding: const EdgeInsets.only(bottom: JoSpace.s2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: JoTheme.meta(context).copyWith(color: p.secondary),
              ),
            ),
            SizedBox(
              width: 120,
              child: JoTextInput(
                initial: '$value',
                onChanged: (v) => onChanged(int.tryParse(v) ?? value),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: 380,
      padding: const EdgeInsets.all(JoSpace.s5),
      decoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '新建段',
            style: JoTheme.ui(context).copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: JoSpace.s3),
          JoTextInput(
            initial: '',
            placeholder: '段名（用作文件名）',
            onChanged: (v) => _name = v,
          ),
          const SizedBox(height: JoSpace.s3),
          num('宽（格）', _width, (v) => _width = v),
          num('高（格）', _height, (v) => _height = v),
          num('origin col', _col, (v) => _col = v),
          num('origin row', _row, (v) => _row = v),
          const SizedBox(height: JoSpace.s3),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              JoButton(text: '取消', onTap: widget.onCancel),
              const SizedBox(width: JoSpace.s2),
              JoButton(
                text: '创建',
                bordered: true,
                onTap: () =>
                    widget.onCreate(_name, _width, _height, _col, _row),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 删除段的确认框。
class DeleteSegmentDialog extends StatelessWidget {
  const DeleteSegmentDialog({
    super.key,
    required this.name,
    required this.onCancel,
    required this.onConfirm,
  });

  final String name;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final p = JoTheme.of(context);
    return Container(
      width: 380,
      padding: const EdgeInsets.all(JoSpace.s5),
      decoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '删除段',
            style: JoTheme.ui(context).copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: JoSpace.s3),
          Text(
            '确定删除「$name」？段文件会一并删除，不能撤销。',
            style: JoTheme.meta(context).copyWith(color: p.text),
          ),
          const SizedBox(height: JoSpace.s4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              JoButton(text: '取消', onTap: onCancel),
              const SizedBox(width: JoSpace.s2),
              JoButton(text: '删除', danger: true, onTap: onConfirm),
            ],
          ),
        ],
      ),
    );
  }
}
