CREATE TYPE "public"."approval_status" AS ENUM('pending', 'allowed', 'denied', 'expired');--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "approvals" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"title" text NOT NULL,
	"payload" jsonb,
	"status" "approval_status" DEFAULT 'pending' NOT NULL,
	"answered_via" text,
	"ttl_seconds" integer DEFAULT 120 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"answered_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "judge_verdicts" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"artifact_hash" text NOT NULL,
	"kind" "scanner_kind" NOT NULL,
	"ruleset_version" text NOT NULL,
	"model_version" text NOT NULL,
	"verdict" "verdict_kind" NOT NULL,
	"severity" text,
	"report_ref" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "approvals" ADD CONSTRAINT "approvals_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "judge_verdicts_key" ON "judge_verdicts" USING btree ("artifact_hash","ruleset_version","model_version");