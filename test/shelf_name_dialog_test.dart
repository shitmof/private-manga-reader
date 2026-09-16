import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_manga_reader/theme.dart';
import 'package:private_manga_reader/widgets/shelf_name_dialog.dart';

/// 规范 4.3：名称不能为空；错误直接显示在输入框附近。
///
/// 原先的两处命名实现（新建/重命名、拖动合组面板）在名称为空时都是
/// **静默返回**——用户点了按钮没有任何反应，也看不到原因。
void main() {
  Future<void> openDialog(
    WidgetTester tester, {
    String initial = '',
    String confirmLabel = '保存',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showShelfNameDialog(
                  context,
                  title: '新建分组',
                  initial: initial,
                  confirmLabel: confirmLabel,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('空名称在输入框内联报错，且对话框不关闭', (tester) async {
    await openDialog(tester, confirmLabel: '创建分组');

    await tester
        .tap(find.byKey(const ValueKey<String>('shelf-name-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.text('名称不能为空'),
      findsOneWidget,
      reason: '空名称必须给出可见错误，而不是点了没反应',
    );
    expect(
      find.byKey(const ValueKey<String>('shelf-name-field')),
      findsOneWidget,
      reason: '校验失败时对话框不能关闭',
    );
  });

  testWidgets('只输入空格同样视为空名称', (tester) async {
    await openDialog(tester, initial: '   ');

    await tester
        .tap(find.byKey(const ValueKey<String>('shelf-name-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('名称不能为空'), findsOneWidget);
  });

  testWidgets('输入有效名称后错误消失', (tester) async {
    await openDialog(tester);

    await tester
        .tap(find.byKey(const ValueKey<String>('shelf-name-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('名称不能为空'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('shelf-name-field')),
      '我的分组',
    );
    await tester.pumpAndSettle();
    expect(
      find.text('名称不能为空'),
      findsNothing,
      reason: '开始输入后应立即清除错误提示',
    );
  });
}
