/**
 * Athena Claude Wrapper Agent
 *
 * Custom Clawd.bot agent that wraps Claude Code CLI for Athena query execution.
 * Handles natural language queries, invokes Claude with project context, and
 * formats results for chat platforms.
 *
 * @see https://docs.clawd.bot/agents/custom
 */

import { spawn } from 'child_process';
import { readFileSync, existsSync, writeFileSync } from 'fs';
import { join } from 'path';

// =============================================================================
// Types
// =============================================================================

interface AgentContext {
  message: string;
  userId: string | number;
  userName?: string;
  channelType: 'telegram' | 'whatsapp' | 'discord';
  groupId?: string | number;
  replyTo?: (text: string) => Promise<void>;
  editMessage?: (messageId: string, text: string) => Promise<void>;
}

interface AllowlistEntry {
  id: number;
  name: string;
}

interface Allowlist {
  telegram?: {
    allowed_users?: AllowlistEntry[];
    allowed_groups?: AllowlistEntry[];
  };
  whatsapp?: {
    allowed_users?: AllowlistEntry[];
    allowed_groups?: AllowlistEntry[];
  };
  discord?: {
    allowed_users?: AllowlistEntry[];
    allowed_guilds?: AllowlistEntry[];
    allowed_channels?: AllowlistEntry[];
  };
  global?: {
    admins?: number[];
    blocklist?: number[];
  };
}

interface QueryResult {
  success: boolean;
  output: string;
  error?: string;
  duration: number;
}

// =============================================================================
// Configuration
// =============================================================================

const CONFIG = {
  // Claude CLI settings
  claudeCliPath: 'claude',
  workspacePath: process.env.WORKSPACE_PATH || '/home/node/workspace',
  timeout: 120000, // 2 minutes max for queries

  // Progress updates
  progressInterval: 10000, // Send progress every 10 seconds

  // Result handling
  maxInlineChars: 3000, // Above this, upload to S3
  s3Bucket: process.env.S3_OUTPUT_BUCKET || 'services-athena-query-output-s3-9707',
  s3Prefix: 'clawd-results/',

  // Allowlist
  allowlistPath: process.env.ALLOWLIST_PATH || '/home/node/config/allowlist.json',
};

// =============================================================================
// Allowlist Validation
// =============================================================================

function loadAllowlist(): Allowlist {
  try {
    if (existsSync(CONFIG.allowlistPath)) {
      const content = readFileSync(CONFIG.allowlistPath, 'utf-8');
      return JSON.parse(content);
    }
  } catch (error) {
    console.error('Failed to load allowlist:', error);
  }
  return {};
}

function isUserAllowed(ctx: AgentContext): boolean {
  const allowlist = loadAllowlist();
  const userId = Number(ctx.userId);

  // Check global blocklist first
  if (allowlist.global?.blocklist?.includes(userId)) {
    return false;
  }

  // Check global admins (always allowed)
  if (allowlist.global?.admins?.includes(userId)) {
    return true;
  }

  // Channel-specific checks
  const channelConfig = allowlist[ctx.channelType];
  if (!channelConfig) {
    // No config for this channel = deny by default
    return false;
  }

  // Check allowed users
  const allowedUsers = channelConfig.allowed_users || [];
  if (allowedUsers.some(u => u.id === userId)) {
    return true;
  }

  // Check allowed groups (if message is from a group)
  if (ctx.groupId) {
    const groupId = Number(ctx.groupId);
    const allowedGroups = channelConfig.allowed_groups || [];
    if (allowedGroups.some(g => g.id === groupId)) {
      return true;
    }
  }

  return false;
}

// =============================================================================
// Progress Updates
// =============================================================================

class ProgressTracker {
  private startTime: number;
  private intervalId?: NodeJS.Timeout;
  private messageId?: string;

  constructor(
    private readonly ctx: AgentContext,
    private readonly onUpdate: (elapsed: number) => string
  ) {
    this.startTime = Date.now();
  }

  start(): void {
    // Send immediate acknowledgment
    this.sendUpdate(0);

    // Start periodic updates
    this.intervalId = setInterval(() => {
      const elapsed = Math.floor((Date.now() - this.startTime) / 1000);
      this.sendUpdate(elapsed);
    }, CONFIG.progressInterval);
  }

  stop(): void {
    if (this.intervalId) {
      clearInterval(this.intervalId);
      this.intervalId = undefined;
    }
  }

  private async sendUpdate(elapsed: number): Promise<void> {
    const message = this.onUpdate(elapsed);
    try {
      if (this.ctx.editMessage && this.messageId) {
        await this.ctx.editMessage(this.messageId, message);
      } else if (this.ctx.replyTo) {
        await this.ctx.replyTo(message);
      }
    } catch (error) {
      console.error('Failed to send progress update:', error);
    }
  }
}

function getProgressMessage(elapsed: number): string {
  if (elapsed === 0) {
    return '⏳ Processing your request...';
  } else if (elapsed < 30) {
    return `⏳ Still working... (${elapsed}s elapsed)`;
  } else if (elapsed < 60) {
    return `⏳ Running Athena query... (${elapsed}s elapsed)`;
  } else {
    return `⏳ Large dataset detected, processing... (${elapsed}s elapsed)`;
  }
}

// =============================================================================
// Claude CLI Execution
// =============================================================================

async function executeClaudeQuery(query: string): Promise<QueryResult> {
  const startTime = Date.now();

  return new Promise((resolve) => {
    const args = [
      '--print', query,
      '--dangerously-skip-permissions'
    ];

    const child = spawn(CONFIG.claudeCliPath, args, {
      cwd: CONFIG.workspacePath,
      env: {
        ...process.env,
        // Ensure project context is available
        CLAUDE_PROJECT_DIR: CONFIG.workspacePath,
      },
      timeout: CONFIG.timeout,
    });

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    child.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    child.on('close', (code) => {
      const duration = Date.now() - startTime;

      if (code === 0) {
        resolve({
          success: true,
          output: stdout.trim(),
          duration,
        });
      } else {
        resolve({
          success: false,
          output: stdout.trim(),
          error: stderr.trim() || `Process exited with code ${code}`,
          duration,
        });
      }
    });

    child.on('error', (error) => {
      const duration = Date.now() - startTime;
      resolve({
        success: false,
        output: '',
        error: error.message,
        duration,
      });
    });
  });
}

// =============================================================================
// S3 Upload (for large results)
// =============================================================================

async function uploadToS3(content: string, queryHash: string): Promise<string | null> {
  try {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const filename = `${timestamp}-${queryHash}.json`;
    const s3Path = `s3://${CONFIG.s3Bucket}/${CONFIG.s3Prefix}${filename}`;

    // Use AWS CLI for upload (available in container)
    const { spawn } = await import('child_process');

    return new Promise((resolve) => {
      const child = spawn('aws', [
        's3', 'cp', '-', s3Path,
        '--content-type', 'application/json',
      ], {
        env: process.env,
      });

      child.stdin.write(content);
      child.stdin.end();

      child.on('close', (code) => {
        if (code === 0) {
          // Generate presigned URL (valid for 24 hours)
          const presignChild = spawn('aws', [
            's3', 'presign', s3Path,
            '--expires-in', '86400',
          ], {
            env: process.env,
          });

          let presignedUrl = '';
          presignChild.stdout.on('data', (data) => {
            presignedUrl += data.toString();
          });

          presignChild.on('close', (presignCode) => {
            if (presignCode === 0) {
              resolve(presignedUrl.trim());
            } else {
              resolve(s3Path); // Fallback to S3 URI
            }
          });
        } else {
          resolve(null);
        }
      });
    });
  } catch (error) {
    console.error('S3 upload failed:', error);
    return null;
  }
}

function hashQuery(query: string): string {
  // Simple hash for query identification
  let hash = 0;
  for (let i = 0; i < query.length; i++) {
    const char = query.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash; // Convert to 32bit integer
  }
  return Math.abs(hash).toString(16);
}

// =============================================================================
// Response Formatting
// =============================================================================

function formatResponse(result: QueryResult, query: string): string {
  if (!result.success) {
    return `❌ **Error**

${result.error || 'Unknown error occurred'}

_Query took ${(result.duration / 1000).toFixed(1)}s_`;
  }

  const output = result.output;

  // Check if result needs S3 upload
  if (output.length > CONFIG.maxInlineChars) {
    return `📊 **Query Results** (large dataset)

_Result too large for inline display._
_Uploading to S3..._

⏳ Please wait...`;
  }

  // Format inline result
  return `✅ **Query Complete**

${output}

_Query took ${(result.duration / 1000).toFixed(1)}s_`;
}

async function formatLargeResponse(
  result: QueryResult,
  query: string
): Promise<string> {
  const output = result.output;
  const queryHash = hashQuery(query);

  // Upload to S3
  const s3Url = await uploadToS3(output, queryHash);

  // Create preview (first 500 chars or first 10 lines)
  const lines = output.split('\n');
  const previewLines = lines.slice(0, 10);
  const preview = previewLines.join('\n').slice(0, 500);
  const hasMore = lines.length > 10 || output.length > 500;

  if (s3Url) {
    return `📊 **Query Results** (${lines.length} lines)

**Preview:**
\`\`\`
${preview}${hasMore ? '\n...' : ''}
\`\`\`

📎 **Full results:** [Download](${s3Url})
_(Link expires in 24 hours)_

_Query took ${(result.duration / 1000).toFixed(1)}s_`;
  } else {
    // S3 upload failed, truncate and warn
    return `📊 **Query Results** (truncated)

**Preview:**
\`\`\`
${preview}${hasMore ? '\n...' : ''}
\`\`\`

⚠️ _Full results could not be uploaded. Showing preview only._

_Query took ${(result.duration / 1000).toFixed(1)}s_`;
  }
}

// =============================================================================
// Main Agent Handler
// =============================================================================

export async function handleMessage(ctx: AgentContext): Promise<void> {
  const { message, replyTo } = ctx;

  // Validate access
  if (!isUserAllowed(ctx)) {
    await replyTo?.(`⛔ **Access Denied**

You are not authorized to use this bot.
Contact admin to request access.

Your ID: \`${ctx.userId}\``);

    console.log(`[SECURITY] Unauthorized access attempt from ${ctx.channelType} user ${ctx.userId}`);
    return;
  }

  // Handle special commands
  if (message.startsWith('/')) {
    await handleCommand(ctx);
    return;
  }

  // Start progress tracking
  const progress = new ProgressTracker(ctx, getProgressMessage);
  progress.start();

  try {
    // Execute Claude CLI with the query
    const result = await executeClaudeQuery(message);

    // Stop progress updates
    progress.stop();

    // Format and send response
    if (result.success && result.output.length > CONFIG.maxInlineChars) {
      const response = await formatLargeResponse(result, message);
      await replyTo?.(response);
    } else {
      const response = formatResponse(result, message);
      await replyTo?.(response);
    }

  } catch (error) {
    progress.stop();

    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    await replyTo?.(`❌ **Unexpected Error**

${errorMessage}

Please try again or contact support.`);

    console.error('[ERROR] Query execution failed:', error);
  }
}

// =============================================================================
// Command Handlers
// =============================================================================

// Bot-local commands (handled directly, not forwarded to Claude CLI)
const LOCAL_COMMANDS = ['start', 'help', 'status', 'id'];

// Claude Code slash commands (forwarded to CLI)
const CLAUDE_COMMANDS: Record<string, { name: string; description: string }> = {
  'athena': { name: '/athena', description: 'Query AWS Athena data warehouse' },
  'sentinel': { name: '/sentinel', description: 'OpenSearch fraud detection AI' },
  'sentinel_athena': { name: '/sentinel-athena', description: 'Athena fraud detection AI' },
  'excalibur': { name: '/excalibur', description: 'Cross-database investigation AI' },
  'msbo_cs': { name: '/msbo-cs', description: 'Customer service investigation' },
  'king_arthur': { name: '/king-arthur', description: 'Multi-agent investigation orchestrator' },
  'aws': { name: '/aws', description: 'AWS operations workflow' },
  'update_schema': { name: '/update-schema', description: 'Sync Athena schema docs' },
  'athena_cli': { name: '/athena-cli', description: 'AWS Athena CLI expert' },
  'email_report': { name: '/email-report', description: 'Generate and send email reports' },
};

async function handleCommand(ctx: AgentContext): Promise<void> {
  const { message, replyTo } = ctx;
  const [rawCommand, ...args] = message.slice(1).split(' ');
  const command = rawCommand.toLowerCase();

  // Handle bot-local commands
  if (LOCAL_COMMANDS.includes(command)) {
    switch (command) {
      case 'start':
      case 'help':
        // Build dynamic help with Claude commands
        const claudeCommandList = Object.entries(CLAUDE_COMMANDS)
          .map(([key, val]) => `• \`${val.name}\` - ${val.description}`)
          .join('\n');

        await replyTo?.(`🤖 **Athena Query Bot**

I can help you query data from AWS Athena using natural language.

**Examples:**
• "What were the top 10 members by stake yesterday?"
• "Show me deposit counts by currency for last week"
• "Find members with multiple accounts sharing the same IP"

**Bot Commands:**
• \`/help\` - Show this help message
• \`/status\` - Check bot status
• \`/id\` - Show your user ID

**AI Commands** _(powered by Claude Code)_:
${claudeCommandList}

Just send me a question or use a command!`);
        break;

      case 'status':
        await replyTo?.(`✅ **Bot Status**

• Gateway: Online
• Claude CLI: Available
• Athena: Connected
• Your ID: \`${ctx.userId}\`
• Channel: ${ctx.channelType}`);
        break;

      case 'id':
        await replyTo?.(`Your ID: \`${ctx.userId}\`
${ctx.userName ? `Username: ${ctx.userName}` : ''}
${ctx.groupId ? `Group ID: \`${ctx.groupId}\`` : ''}`);
        break;
    }
    return;
  }

  // Check if it's a known Claude command (with underscore -> hyphen mapping)
  const claudeCmd = CLAUDE_COMMANDS[command];
  if (claudeCmd) {
    // Forward to Claude CLI with the proper command name
    const fullQuery = `${claudeCmd.name} ${args.join(' ')}`.trim();
    await forwardToClaudeCli(ctx, fullQuery);
    return;
  }

  // Unknown command - try forwarding to Claude CLI anyway (might be a plugin command)
  // This allows commands like /verrueckt-task:debug to work
  const fullMessage = `/${rawCommand} ${args.join(' ')}`.trim();
  await forwardToClaudeCli(ctx, fullMessage);
}

/**
 * Forward a command/query to Claude CLI and handle the response
 */
async function forwardToClaudeCli(ctx: AgentContext, query: string): Promise<void> {
  const { replyTo } = ctx;

  // Start progress tracking
  const progress = new ProgressTracker(ctx, getProgressMessage);
  progress.start();

  try {
    const result = await executeClaudeQuery(query);
    progress.stop();

    if (result.success && result.output.length > CONFIG.maxInlineChars) {
      const response = await formatLargeResponse(result, query);
      await replyTo?.(response);
    } else {
      const response = formatResponse(result, query);
      await replyTo?.(response);
    }
  } catch (error) {
    progress.stop();
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    await replyTo?.(`❌ **Command Error**

${errorMessage}

Please try again or use \`/help\` for available commands.`);
    console.error('[ERROR] Command execution failed:', error);
  }
}

// =============================================================================
// Export for Clawd.bot
// =============================================================================

export default {
  name: 'athena-claude-wrapper',
  description: 'Athena data queries via Claude Code CLI',
  handleMessage,
};
