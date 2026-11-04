# Releasing

How a version of DCCAtlas reaches Unraid and anyone who pulls the image.

1. Run every suite in [TESTING.md](TESTING.md): the Perl suite, the web
   suite, the browser checks, the container checks, and the three offline
   labs. The **Tests** workflow (`.github/workflows/tests.yml`) runs all but
   the labs on every push to `main`; its run for the commit must have
   passed before tagging.
2. Add the version to [CHANGES.md](CHANGES.md): what changed for someone
   using it, and what the update does to data kept from before.
3. Tag the tested commit and push the tag:

   ```sh
   git tag v1.0.0
   git push origin v1.0.0
   ```

4. The **Image** workflow (`.github/workflows/image.yml`) builds
   `deploy/Dockerfile` and publishes `ghcr.io/captainepix/dccatlas:1.0.0`
   and `:latest`. The package takes the repository's visibility. Nothing is
   published from a push to `main`; a manual run of the workflow publishes
   the branch as `:edge`. Only `CaptainEpix/DCCAtlas` publishes: in any
   other copy of the repository the workflow does nothing.
5. Unraid's "Check for updates" then offers the new `:latest`.

Dependabot (`.github/dependabot.yml`) opens a pull request each month for a
newer base image, Python package or action. The base image is Irssi on
Debian, which parses everything IRC servers send, so merge those and
release rather than let them wait.

The Unraid template lives in
[CaptainEpix/dccatlas-unraid](https://github.com/CaptainEpix/dccatlas-unraid)
(`templates/dccatlas.xml`). Change it there when a setting is added; Community
Applications reads it from that repository.
