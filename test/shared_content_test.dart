import 'package:conest/src/platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads what Android passes on from a share', () {
    final shared = SharedContent.fromPlatform({
      'files': [
        {
          'path': '/cache/shared/1/0-a.jpg',
          'name': '0-a.jpg',
          'mimeType': 'image/jpeg',
        },
        {'path': '/cache/shared/1/1-b.pdf', 'name': '1-b.pdf'},
        {'name': 'no path'},
        'junk',
      ],
      'text': 'look at this',
    })!;
    expect(shared.files.map((file) => file.name), ['0-a.jpg', '1-b.pdf']);
    expect(shared.files.last.mimeType, 'application/octet-stream');
    expect(shared.text, 'look at this');
    expect(SharedContent.fromPlatform({'files': [], 'text': ''}), isNull);
    expect(SharedContent.fromPlatform(null), isNull);
    expect(
      SharedContent.fromPlatform({'text': 'only text'})!.text,
      'only text',
    );
  });
}
