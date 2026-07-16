import 'package:chat_group/features/agentic/agent_runtime_components.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('protocol parser recovers loose workspace patch payloads', () {
    final request = AgentProtocolParser.parse('''
<function=workspace.patch>
{"path":"notes.md","content":"hello"}
</function>
''');

    expect(request?.tool, AgentToolName.workspacePatch);
    expect(request?.args['path'], 'notes.md');
    expect(request?.args['content'], 'hello');
  });
}
