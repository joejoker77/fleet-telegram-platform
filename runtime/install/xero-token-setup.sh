#!/usr/bin/env bash
# SUPERSEDED 2026-08-21 — do not use this script.
#
# The Xero token-service setup was folded into the one script that already asks for
# integration credentials and distributes them by role, so there is a single flow
# instead of two that can drift apart:
#
#     /opt/ftp-src/fleet-telegram-platform/runtime/install/onboard-integrations.sh
#
# Run it and answer y at "Configure Xero? (token services — Monaco CMS and Grapple n8n)".
# It asks for one bearer per organisation, proves each one end to end against Xero before
# storing anything, and binds them to exactly the agents entitled to Xero.
#
# This file is a signpost only: deleting it needs an operator (the host broker refuses
# destructive commands), so it was emptied rather than left as a working duplicate.
echo "This script is superseded. Use:" >&2
echo "  bash /opt/ftp-src/fleet-telegram-platform/runtime/install/onboard-integrations.sh" >&2
echo "and answer y at the Xero question." >&2
exit 64
