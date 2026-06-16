ALTER TABLE "installs" DROP CONSTRAINT "installs_artifact_version_id_artifact_versions_id_fk";
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "installs" ADD CONSTRAINT "installs_artifact_version_id_artifact_versions_id_fk" FOREIGN KEY ("artifact_version_id") REFERENCES "public"."artifact_versions"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
