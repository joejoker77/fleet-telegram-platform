CREATE TYPE "public"."artifact_status" AS ENUM('draft', 'scanning', 'published', 'rejected');--> statement-breakpoint
ALTER TABLE "artifact_versions" ADD COLUMN "status" "artifact_status" DEFAULT 'draft' NOT NULL;--> statement-breakpoint
ALTER TABLE "artifact_versions" ADD COLUMN "scan_summary" jsonb;--> statement-breakpoint
ALTER TABLE "artifacts" ADD COLUMN "description" text;--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "artifacts_owner_type_name_key" ON "artifacts" USING btree ("owner_user_id","type","name");