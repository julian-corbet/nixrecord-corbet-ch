#
# The cluster catalogue: what nixrecord's cluster-side applications ARE.
#
# WHY THIS REPOSITORY HAS A CLUSTER SIDE AT ALL. Everything else here runs on the one host that
# holds the camera, the microphone and the encoder, because that is where a capture physically
# happens. What happens to a capture AFTERWARDS does not: publishing an episode and running a show
# are both continuous services with an audience, and an audience does not wait for a laptop to be
# open. So the same subject -- recording, publishing and playing out media -- has two planes, and
# this file is the catalogue for the second one.
#
# WHAT BELONGS HERE. The placement rule the README states for the capture side decides this side
# too, read one step further along: this repository owns the real event and the artefact made of
# it. A podcast host is the publishing end of a recording; a run-of-show timer is the live end of
# one. Playback of somebody else's library is not here, and neither is transcoding a file that
# already exists -- those have owners of their own, and the fact that both touch media files is
# exactly why the boundary is drawn on the EVENT rather than on the file type.
#
# WHAT IS KNOWLEDGE AND WHAT IS A VALUE. Everything in this file is true of the software wherever
# anyone runs it: the port it listens on, the directory it writes, the environment variables it
# cannot start without, the SHAPE of its probes -- which ones exist, what they ask for, and which
# one must not exist at all -- what it needs from the kernel, whether it writes anywhere but the
# directory it declares, and whether anything is lost while it is not running. Nothing here names
# an address, a node, a hostname, a namespace, a storage path, a share of somebody's hardware or a
# secret's contents -- those are one deployment's facts and they arrive from the consumer. The
# split is enforced rather than trusted: `state` here is the path INSIDE the container, and what
# backs it can only be supplied by a declaration; the probe SHAPES are here and their BUDGETS can
# be re-tuned by a declaration, because how long a start takes is a fact about a machine.
{}:
{
  applications = {
    castopod = {
      # Docker Hub, published by the project itself. The catalogue carries the REPOSITORY only: a
      # version is a deployment's choice, and for this application in particular it is a choice
      # with a schema migration attached -- see the note.
      image = "castopod/castopod";
      ports.http = 8080;
      primaryPort = "http";

      # ONE DIRECTORY, holding uploaded episode audio and cover art. Everything else this
      # application knows lives in a database it does not run, which is why the persistence story
      # is one path rather than a volume per concern. A media directory is a SINGLE-WRITER
      # resource: two pods holding it is two writers, so the deployment cannot roll -- the old pod
      # must be gone before the new one starts. A consumer never states that; declaring state is
      # what states it.
      state.media = "/var/www/castopod/public/media";

      # The environment it cannot start without, listed by NAME. These are the software's own
      # documented variables, so they are knowledge; every one of their VALUES is either a
      # credential or one installation's address, so none of them can be set here. The module
      # refuses a declaration that does not hand it a Secret carrying them.
      secretEnv = [
        "CP_DATABASE_HOSTNAME"
        "CP_DATABASE_NAME"
        "CP_DATABASE_USERNAME"
        "CP_DATABASE_PASSWORD"
        "CP_BASEURL"
        "CP_CACHE_HANDLER"
      ];

      env = { };
      args = [ ];

      # Three minutes of patience, and the number is the migration rather than the traffic: 20
      # seconds before the first probe, then 18 failures at 10-second intervals.
      readiness = {
        path = "/";
        initialDelaySeconds = 20;
        periodSeconds = 10;
        failureThreshold = 18;
      };

      # NO LIVENESS PROBE, and this is a decision rather than an omission. A liveness probe on an
      # application that may be part-way through a schema migration restarts the container mid
      # migration -- which is how a slow start becomes a restart loop that looks like the
      # application's fault and is not.
      liveness = null;

      # WHAT THE PROCESS NEEDS FROM THE KERNEL, AND WHERE IT WRITES. Both halves are properties of
      # the image rather than of a cluster, which is why they are stated here -- and both are
      # stated as what has been ESTABLISHED rather than as what sounds prudent. A restriction
      # nobody verified is not hardening; it is a container that fails to start, reporting a
      # permission rather than the setting that denied it.
      hardening = {
        # NOT ESTABLISHED, and therefore nothing is applied. This is a PHP application behind a web
        # server inside one image, with an entrypoint that arranges its own runtime directories on
        # start; which of that path's steps need a capability has not been established here, and
        # this repository does not assert a profile it has not checked. The consequence is visible
        # rather than hidden: nothing is rendered, so the container carries no securityContext and
        # a reader can see that the question is open.
        privileges = "unestablished";

        # IT WRITES OUTSIDE THE DIRECTORY IT DECLARES, by design and not by accident. The cache
        # handler writes to the container's own filesystem, and that is exactly the trade that
        # makes this one container instead of a pair (see the note). A read-only root takes it
        # away, so asking for one is refused rather than granted.
        rootFilesystem = "writable";
      };

      # IT MAY NOT IDLE. Not because it is large -- it is not -- but because of who calls it: see
      # the note.
      idle = "unsafe";

      note = ''
        A podcast host: the publishing end of a recording. Episodes are uploaded, a feed is
        generated, and clients all over the internet fetch that feed on their own schedule.

        IT DOES NOT RUN ITS OWN DATABASE, and that is the first fact to plan around. The schema
        lives on an external MySQL/MariaDB server that somebody else operates; this container is a
        PHP application with a web server already inside the image, and nothing else. So the
        deployment is one container -- which is the reason it is expressible in a plain app
        grammar at all -- and the price is that its database coordinates arrive as environment,
        every one of them either a credential or one installation's address.

        IT MIGRATES THE SCHEMA IT SHARES, on start, without being asked. That single behaviour is
        why the image should be pinned by DIGEST rather than a tag: a floating tag is a schema
        change that happens whenever the registry feels like it, on a database this application
        does not own, and afterwards there is no diff to read. It is also why the readiness budget
        is measured in minutes and why there is no liveness probe at all.

        THE CACHE IS REGENERABLE AND THEREFORE NOT STATE. It can be handed to a separate cache
        service, and it can also be written to the container's own filesystem, which is what makes
        this a single-container application rather than a pair. Running a second service purely to
        hold data that can be rebuilt is a trade, and the catalogue records that the trade exists
        rather than making it.

        IT MAY NOT SLEEP, and the reason is the audience rather than the size. Podcast clients poll
        a feed on a schedule nobody here controls, so "nobody is using it" is not a state this
        application reliably reaches. And a cold start that has to boot PHP and shake hands with a
        remote database in front of a feed fetch is not a wake -- it is a timeout, seen by a client
        that will simply record the feed as broken.
      '';
    };

    ontime = {
      # Docker Hub, published by the project itself. Repository only, for the same reason as above.
      image = "getontime/ontime";
      ports.http = 4001;
      primaryPort = "http";

      # ONE DIRECTORY, and unusually it is READABLE: application state, rundown projects, styles,
      # translations and uploaded assets, all as plain JSON and files rather than an opaque
      # database. That makes it inspectable and directly backup-able, and changes nothing about the
      # writer count -- exactly one instance may ever hold this tree, so the deployment cannot
      # roll.
      state.data = "/data";

      # Nothing. It has no database, no external service and no credential of its own, so there is
      # nothing a Secret would have to carry.
      secretEnv = [ ];

      # Where it writes, said in the software's own terms, and therefore knowledge rather than a
      # value: the mount path above is the same fact, and the two would be free to disagree if one
      # of them lived in a deployment. `NODE_ENV` selects the container-image behaviour the image
      # is built for. A time zone is NOT here -- which clock a show runs on is a property of the
      # show, and it arrives from the declaration.
      env = {
        NODE_ENV = "docker";
        ONTIME_DATA = "/data/";
        CA_TS_FALLBACK_DIR = "/data/";
      };

      args = [ ];

      # Two minutes of patience at a five-second interval. Patient because the request most likely
      # to be waiting on it is the first one after an idle period, not because the application is
      # slow: it holds no migrations and starts fast.
      readiness = {
        path = "/";
        periodSeconds = 5;
        failureThreshold = 24;
      };

      # A liveness probe, written on purpose rather than synthesized. It is far less patient than
      # readiness (90 seconds) because it judges a process that has already come up once, and the
      # thing it is there to catch is a hang during a live show.
      liveness = {
        path = "/";
        periodSeconds = 15;
        failureThreshold = 6;
      };

      # WHAT THE PROCESS NEEDS FROM THE KERNEL, AND WHERE IT WRITES -- the same two questions, with
      # answers, which is the difference that decides what gets rendered.
      hardening = {
        # IT NEEDS NOTHING. One Node process, one port well above 1024, no setuid path, and nothing
        # it does requires gaining a privilege it did not start with. So every capability goes and
        # escalation is denied -- and because that is knowledge about the software rather than a
        # preference, it applies wherever this application is declared instead of being opted into
        # one cluster at a time.
        privileges = "none";

        # EVERYTHING IT WRITES IS THE DIRECTORY ABOVE: state, rundowns, styles, translations and
        # uploaded assets all land under one path, and there is no second place. That makes a
        # read-only root filesystem POSSIBLE, which is a different statement from "on". Being the
        # first installation to run it that way is a risk somebody takes on a particular day, so
        # this half only UNLOCKS the term; a declaration still has to ask for it.
        rootFilesystem = "state-only";
      };

      # IT MAY IDLE -- with a boundary that is written down rather than assumed. See the note.
      idle = "safe";

      note = ''
        A live-event timer and rundown editor: the run-of-show side of production. Somebody builds
        the order of a show, and on the day it counts down, drives the stage displays and tells
        everybody where the show actually is against where it was meant to be.

        IT IS SELF-CONTAINED. One process, one port, no database, no companion service. What it
        keeps is a small tree of readable files, so the whole persistence story is one directory
        and it can be read with an ordinary text editor -- which matters more than it sounds,
        because a rundown is a document somebody wrote and losing it is losing work rather than
        losing a cache.

        ITS DATA DIRECTORY IS CURATED FROM OUTSIDE. The files were put there by a person and are
        owned by whatever put them there. Nothing in this repository can ask a cluster to take
        group ownership of that directory, because the mechanism for doing so recursively rewrites
        ownership on every single start, and doing that to a curated tree destroys something
        deliberate. The absence is the guarantee: there is no term here for asking.

        THE WEB FACE MAY SLEEP, and only the web face. Between shows nothing fires on a timer,
        nothing watches a directory, and an editor nobody has open is doing no work -- so zero
        replicas loses nothing and the first request pays a cold start it can afford. What may NOT
        sleep is the control side: this application also speaks a long-lived control protocol over
        UDP to lighting and sound, and there is no request to wake on in a channel that is simply
        expected to be there. An installation that needs those integrations needs a resident copy;
        that is a different deployment, not a flag.

        PIN IT. It reads and rewrites its own on-disk format, so an unpinned reference is a data
        migration that happens on a pod restart -- during a show, at the moment the pod restarts,
        which is the worst time this application has.
      '';
    };
  };
}
