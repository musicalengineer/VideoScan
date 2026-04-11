Continuous Improvement Ideas for VideoScan App	April 2026

Bugs, Issues, Needs investigation, or TBD, etc. In no particular order:
	
- Face detection is still not accurate. This may be an alg thing, keep thinking about this.
- DLIB alg either not working or needs a lot more attention. RT FD window empty when using DLIB.
- Hybrid needs to be exercised and tested
- other algs we can try, at least start thinking about trying
- think about whether we're going down a rabbit hole on FD, should we train a model on the family media? why is this crazy and maybe it will be a great new model that everyone didn't know they needed.
- verify we can use multiple FD algs one different volumes
- where do we see bad files? Is there a column for files that cannot be recovered and candidate for deletion. Can I see only those files and maybe delete them. Maybe I can even move the source material into folders by decade, useful, needs-work, rejected. Need to think about this and how to do it over a network.
- Background info: The old cheesegrater MacPro cannot run the app so I have to do this remote volumes, but may consider copying everything to local storage, but I don't want to copy junk, if I can help it.

- Long duplicate detections, correlations, or combine operations need visual progress indicator so user has some idea of what's going on. maybe we can have a progress bar or something

- When we combine a bunch of files, where do they go? 

- When we hover over columns can we have popups that explain a bit more, for any column that might need more explaining, such as Avid Bins?

- When I click on Avid Bins, it says 23, does this mean it processed metadata from those bins successfully?

- Better and/or more FD algs selectable ... at least to try and confirm our modular plugin architecture.

Unit Tests and Smoke Tests:
- Think about f this is helpful for us, esp as app gets more functionality... We may need some smoke tests and/or FD unit tests on some stock images or something. We want to detect failures early and create bug lists as we get more professional and more features. If the App can't detect a given "test" face in a given "test" video, that alg is broken and we know it every time we run unit/smoke tests.  

- Periodic Code Checking to make sure we're following best practices regarding Swift, Modularity, files/functions per etc. Just wanna prevent overloading and making files too huge or functions too long. Remember, object oriented code design, or best practices in general, will pay for itself.

Examples of End User Scenarios:

- Scenario: someone's birthday or special occassion, use this app to scan all the videos on these drives and network drives, find anything with the person, compile a clip for that special occassion which user can edit as needed. 

- Long term use case is to comb thru video archives, find people we care about and save/organize these, deleting the duplicates (by hand? probably) then archiving valuable stuff to cloud, MDISC media, or somewhere (User probably does this part).



