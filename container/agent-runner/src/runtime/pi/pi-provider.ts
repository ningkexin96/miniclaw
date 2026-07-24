import type { Model } from '@earendil-works/pi-ai';
import { getModel } from '@earendil-works/pi-ai/compat';
import type { ModelRuntime } from '@earendil-works/pi-coding-agent';

export type PiProviderResolution = {
  providerId: string;
  modelId: string;
  model: Model<any>;
};

function splitModelRef(value: string): { providerId: string; modelId: string } {
  const slash = value.indexOf('/');
  if (slash <= 0 || slash === value.length - 1) {
    return { providerId: 'anthropic', modelId: value };
  }
  return {
    providerId: value.slice(0, slash),
    modelId: value.slice(slash + 1),
  };
}

/**
 * Parse the Claude-Code style `ANTHROPIC_CUSTOM_HEADERS` env value into the
 * header map Pi attaches to every request. The value is one `Name: value` pair
 * per line; malformed lines are skipped rather than failing the whole run.
 * Gateways that route by an extra header (for example OpenCode Zen's
 * `x-opencode-session`) depend on this.
 */
export function parseCustomHeaders(
  raw: string | undefined,
): Record<string, string> | undefined {
  if (!raw?.trim()) return undefined;
  const headers: Record<string, string> = {};
  for (const line of raw.split('\n')) {
    const entry = line.trim();
    if (!entry) continue;
    const separator = entry.indexOf(':');
    if (separator <= 0) continue;
    const name = entry.slice(0, separator).trim();
    const value = entry.slice(separator + 1).trim();
    if (name && value) headers[name] = value;
  }
  return Object.keys(headers).length > 0 ? headers : undefined;
}

/**
 * Bridge the existing Miniclaw provider env contract to Pi ModelRuntime.
 * Custom Anthropic-compatible endpoints are registered as a separate provider
 * so Pi's built-in Anthropic catalog and credentials remain untouched.
 */
export async function resolvePiProvider(
  modelRuntime: ModelRuntime,
  input: {
    model?: string;
    endpointKind?: 'official' | 'custom';
    baseUrl?: string;
    apiKey?: string;
    customHeaders?: string;
  },
): Promise<PiProviderResolution> {
  const rawModel = input.model?.trim() || '';
  if (!rawModel && input.endpointKind !== 'custom' && !input.baseUrl?.trim()) {
    const defaultModel = modelRuntime.getModels('anthropic')[0];
    if (!defaultModel) {
      throw new Error(
        'Pi has no built-in Anthropic model. Configure ANTHROPIC_MODEL or Pi models.json.',
      );
    }
    if (input.apiKey?.trim()) {
      await modelRuntime.setRuntimeApiKey('anthropic', input.apiKey.trim());
    }
    return {
      providerId: defaultModel.provider,
      modelId: defaultModel.id,
      model: defaultModel,
    };
  }
  const split = splitModelRef(rawModel || 'claude-sonnet');
  const custom = input.endpointKind === 'custom' || !!input.baseUrl?.trim();
  const providerId = custom
    ? `miniclaw-${split.providerId}`
    : split.providerId;

  if (custom) {
    if (!input.baseUrl?.trim()) {
      throw new Error('Pi custom provider requires ANTHROPIC_BASE_URL');
    }
    if (!rawModel) {
      throw new Error('Pi custom provider requires ANTHROPIC_MODEL');
    }
    const customHeaders = parseCustomHeaders(input.customHeaders);
    modelRuntime.registerProvider(providerId, {
      name: `Miniclaw ${split.providerId} compatible provider`,
      baseUrl: input.baseUrl.trim(),
      api: 'anthropic-messages',
      ...(input.apiKey?.trim() ? { apiKey: input.apiKey.trim() } : {}),
      ...(customHeaders ? { headers: customHeaders } : {}),
      models: [
        {
          id: split.modelId,
          name: split.modelId,
          api: 'anthropic-messages',
          reasoning: true,
          input: ['text', 'image'],
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          contextWindow: 200_000,
          maxTokens: 32_000,
        },
      ],
    });
  } else if (input.apiKey?.trim() && providerId === 'anthropic') {
    await modelRuntime.setRuntimeApiKey('anthropic', input.apiKey.trim());
  }

  const model =
    modelRuntime.getModel(providerId, split.modelId) ||
    (custom
      ? undefined
      : (
          getModel as unknown as (provider: string, model: string) => Model<any>
        )(providerId, split.modelId));
  if (!model) {
    throw new Error(
      `Pi model not found: ${providerId}/${split.modelId}. Configure ANTHROPIC_MODEL or Pi models.json.`,
    );
  }
  return { providerId, modelId: split.modelId, model };
}
