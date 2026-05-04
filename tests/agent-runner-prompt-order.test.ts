import { describe, expect, test } from 'vitest';
import { buildHappyClawPromptPlan } from '../container/agent-runner/src/prompt-plan.js';

describe('agent-runner system prompt composition order', () => {
  test('Agent identity leads platform workspace/context material', () => {
    const plan = buildHappyClawPromptPlan({
      platformIdentity: 'HappyClaw',
      platformBootstrap: 'first wake',
      agentIdentity: 'identity',
      interaction: 'interaction',
      security: 'security',
      output: 'output',
    });
    expect(plan.blocks.map((block) => block.id)).toEqual([
      'identity.happyclaw',
      'bootstrap.happyclaw',
      'agent-profile',
      'interaction',
      'security-rules',
      'output',
    ]);
  });
});
