Ideas and Brainstorming for Video Scanner App April 10, 2026

- Bugs, Performance Issues, etc:
	- Failures encountered by python scripts, ffprobe, do not seem logged to console in enough detail. I was trying to figure out what the failures were but there was nothing in the log. Does The Command Executor module capture enough detail so we can see it in the log or is there another log we can look at if we're using a subsystem, since things may be modular.

	- Any logs that from this app or indirectly useful to this app should be listed in the Settings window or a new pane entitled Logs. Being able to "Reveal in finder" or "Edit with..." is fine. 
	
	- Pause/Start/Restart buttons seem to have trouble in catalog scanner. I paused eerything in catalog scanner but the dashboard showed it was still working... Probing 28%, 3 hours remaining. If it is paused, why is it showing this?
	
	- RE: pause... if we pause then shutdown the app or the volume goes away, does catalog scan have to start from scratch? I'm not sre, it'd be nice to know what the status is, interrupted, resumed OK or not.

	- very very slow discovering avb files ... could be that these are on a network volume, but the app must perform on network volumes, I thought it would copy to the ram cache and this is Gig Enet so why so slow. This is a performance enhancement not a bug so much, but it feels like a bug in practice
	
	- Face detection is still a bit innaccurate. This may be an architecture thing, not so much a bug, not sure yet

Features & Tweaks:

- RT catalog scan window looks great and colorful, but we need to reduce font by 2 points or 15% to match VideoScan Dashboard.

- Unit Tests and Smoke Tests - I feel like we need to build clear FD unit tests on some stock images or something. In other words, this may be a smoke test, but if it can't detect a given test face in a given test video, all short, then it's broken and we know it early. We can't go forward if it is broken.

- Better and/or more FD algs selectable 

- FYI, an Ideal scenario is: when it is someone's birthday or special occassion, I want to use this app to scan all the videos on these drives and network drives in my house, find anything with them, and choose a small Happy Birthday or special occassion clip. This is an example of one use case, keep it in mind. The long term use case is combing through the video archives, finding people we care about, deleting the duplicates (by hand) and archiving the valuable stuff to the cloud or somewhere (I do this part).

- 

