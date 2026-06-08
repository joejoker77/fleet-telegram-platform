CREATE TYPE "public"."artifact_type" AS ENUM('skill', 'subagent', 'command', 'mcp', 'workflow', 'plugin');--> statement-breakpoint
CREATE TYPE "public"."scanner_kind" AS ENUM('mcp', 'skill', 'agentshield', 'promptfoo');--> statement-breakpoint
CREATE TYPE "public"."sub_tier" AS ENUM('base', 'extended');--> statement-breakpoint
CREATE TYPE "public"."user_status" AS ENUM('provisioned', 'active', 'idle', 'suspended', 'deleted');--> statement-breakpoint
CREATE TYPE "public"."verdict_kind" AS ENUM('pass', 'fail', 'error');--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "artifact_versions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"artifact_id" uuid,
	"version" text NOT NULL,
	"git_ref" text,
	"provenance" jsonb,
	"published_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "artifacts" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"owner_user_id" uuid,
	"type" "artifact_type" NOT NULL,
	"name" text NOT NULL,
	"visibility" text DEFAULT 'private' NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "audit_index" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"user_id" uuid,
	"kind" text,
	"ref" text,
	"ts" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "containers" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"container_id" text,
	"state" text NOT NULL,
	"cpu_weight" integer,
	"cpu_quota" integer,
	"mem_high" bigint,
	"mem_max" bigint,
	"last_active_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "installs" (
	"user_id" uuid,
	"artifact_version_id" uuid,
	"installed_at" timestamp with time zone DEFAULT now() NOT NULL,
	"pinned_version" text,
	CONSTRAINT "installs_user_id_artifact_version_id_pk" PRIMARY KEY("user_id","artifact_version_id")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "scan_results" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"artifact_version_id" uuid,
	"scanner" "scanner_kind" NOT NULL,
	"verdict" "verdict_kind" NOT NULL,
	"severity" text,
	"report_ref" text,
	"judge_cache_hit" boolean,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "secret_bindings" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid,
	"placeholder" text NOT NULL,
	"host" text NOT NULL,
	"path" text,
	"injection" jsonb
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "sessions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid,
	"session_name" text NOT NULL,
	"claude_session_id" text,
	"state" text NOT NULL,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_message_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "subscriptions" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"tier" "sub_tier" NOT NULL,
	"status" text NOT NULL,
	"valid_until" timestamp with time zone,
	"anthropic_seat" text
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "usage_records" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"user_id" uuid,
	"window" text,
	"tokens" bigint,
	"compute" numeric,
	"model" text,
	"ts" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "users" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"telegram_user_id" bigint NOT NULL,
	"os_username" text NOT NULL,
	"role" text,
	"is_admin" boolean DEFAULT false NOT NULL,
	"status" "user_status" DEFAULT 'provisioned' NOT NULL,
	"approved_by" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "users_telegram_user_id_unique" UNIQUE("telegram_user_id"),
	CONSTRAINT "users_os_username_unique" UNIQUE("os_username")
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "artifact_versions" ADD CONSTRAINT "artifact_versions_artifact_id_artifacts_id_fk" FOREIGN KEY ("artifact_id") REFERENCES "public"."artifacts"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "artifacts" ADD CONSTRAINT "artifacts_owner_user_id_users_id_fk" FOREIGN KEY ("owner_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "containers" ADD CONSTRAINT "containers_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "installs" ADD CONSTRAINT "installs_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "installs" ADD CONSTRAINT "installs_artifact_version_id_artifact_versions_id_fk" FOREIGN KEY ("artifact_version_id") REFERENCES "public"."artifact_versions"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "scan_results" ADD CONSTRAINT "scan_results_artifact_version_id_artifact_versions_id_fk" FOREIGN KEY ("artifact_version_id") REFERENCES "public"."artifact_versions"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "secret_bindings" ADD CONSTRAINT "secret_bindings_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "sessions" ADD CONSTRAINT "sessions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "subscriptions" ADD CONSTRAINT "subscriptions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "usage_records" ADD CONSTRAINT "usage_records_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "users" ADD CONSTRAINT "users_approved_by_users_id_fk" FOREIGN KEY ("approved_by") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
