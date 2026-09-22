import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, test } from 'vitest';

describe('Feishu route safety integration', () => {
  test('treats a configured resolver returning null as a dropped message', () => {
    const source = fs.readFileSync(
      path.join(process.cwd(), 'src/feishu.ts'),
      'utf8',
    );

    expect(source).toContain('resolveAdmittedChannelRoute<FeishuMessageMeta>');
    expect(source).toContain(
      'Feishu binding resolver rejected route; dropping message',
    );
    expect(source).not.toContain('agentRouting?.effectiveJid ?? chatJid');
  });

  test('bootstraps an unregistered P2P chat before the route check, so the first-ever DM is not fail-closed forever', () => {
    const source = fs.readFileSync(
      path.join(process.cwd(), 'src/feishu.ts'),
      'utf8',
    );

    // P2P has no external "bot added" event like groups (onBotAddedToGroup)
    // and no /pair step like other channels, so the first DM must be able
    // to register the chat itself before resolveAdmittedChannelRoute is
    // consulted — otherwise a brand-new chat can never pass the route check
    // that must precede its own registration, dropping every message
    // forever. See channel-admission.ts's "pairing establishes ownership
    // before routing" contract.
    //
    // The configured resolver reports "no route" by throwing
    // ChannelRouteRejectedError (im-manager's scopeConnectOpts), so the
    // bootstrap probe must tolerate that rejection instead of letting it
    // abort registration.
    const bootstrapIdx = source.indexOf('!hasResolvableRoute');
    const routeCheckIdx = source.indexOf(
      'resolveAdmittedChannelRoute<FeishuMessageMeta>',
    );

    expect(source).toContain('err instanceof ChannelRouteRejectedError');
    expect(bootstrapIdx).toBeGreaterThan(-1);
    expect(routeCheckIdx).toBeGreaterThan(-1);
    expect(bootstrapIdx).toBeLessThan(routeCheckIdx);
  });
});
