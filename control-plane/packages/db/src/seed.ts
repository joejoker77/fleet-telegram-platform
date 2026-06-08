// Idempotent seed for the pilot tenant (vitaliy). Safe to run repeatedly:
// uses ON CONFLICT DO NOTHING on the natural keys.
//
// Run: DATABASE_URL=... pnpm --filter @fleet/db seed
//
// NOTE: telegram_user_id for the vitaliy pilot is the Telegram chat_id 2112420187
// (same value used everywhere as the Composio user_id). os_username = "vitaliy".

import { getDb, getPool } from "./index.js";
import { users, subscriptions } from "./schema.js";
import { sql } from "drizzle-orm";

const PILOT = {
  telegramUserId: 2112420187,
  osUsername: "vitaliy",
  role: "owner",
  isAdmin: true,
} as const;

async function main() {
  const db = getDb();

  const inserted = await db
    .insert(users)
    .values({
      telegramUserId: PILOT.telegramUserId,
      osUsername: PILOT.osUsername,
      role: PILOT.role,
      isAdmin: PILOT.isAdmin,
      status: "active",
    })
    .onConflictDoNothing({ target: users.telegramUserId })
    .returning({ id: users.id });

  const row =
    inserted[0] ??
    (await db
      .select({ id: users.id })
      .from(users)
      .where(sql`${users.telegramUserId} = ${PILOT.telegramUserId}`))[0];

  if (!row) throw new Error("failed to resolve pilot user id");

  await db
    .insert(subscriptions)
    .values({ userId: row.id, tier: "extended", status: "active" })
    .onConflictDoNothing({ target: subscriptions.userId });

  console.log(`seeded pilot tenant: os_username=${PILOT.osUsername} user_id=${row.id}`);
}

main()
  .then(() => getPool().end())
  .catch(async (err) => {
    console.error(err);
    await getPool().end();
    process.exit(1);
  });
