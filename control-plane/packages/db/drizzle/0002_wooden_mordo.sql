ALTER TABLE "usage_records" ADD COLUMN "input_tokens" bigint;--> statement-breakpoint
ALTER TABLE "usage_records" ADD COLUMN "output_tokens" bigint;--> statement-breakpoint
ALTER TABLE "usage_records" ADD COLUMN "cache_read_tokens" bigint;--> statement-breakpoint
ALTER TABLE "usage_records" ADD COLUMN "cache_creation_tokens" bigint;