1. Purpose
This app hosts and organizes family multimedia and family ancestry information. It has the following primary Tabs or foci for the user:
		
People Tab: This tab has the current and recent generation of immediate family. Some members in this tab are recently deceased but it is your typical family, a man & woman married with fours sons and grandparents. The people tab focuses on People and also groups, ie, Families like "The Rick & Donna Breen" Family. The people tab allows the user to click on a person and edit their essential vital stats, show videos associated with that person, and it previously allowd searching for that person in video files but we found people in the family look too similar for those algs to really have a high enough success rate to be practicable. this code may be reused or retired, not sure yet. 

Catalog Tab: Holds the media catalog and displays this to the user in various helpful ways, allows for search, etc. The catalog has Content Analysis and Event Analysis and other tools like 

Storage Tab: Is a pretty colorful but technical view of the catalog, the files, and the storage underlying the catalog geared to helping the user understand how the files are distributed and how safe they are and how performant a drive is and its age and technology, ie, SSD, HDD, RAID, etc.

Triage Tab: Of questionable value, but originally conceoved to help the user identify broken pairs of A/V that need to be merged or repaired. Also aids in duplicate detection and reducing the number of copies. Identify junk, delete junk, etc.

Archive Tab: Shows the media by decades and years with tahs and highlights indicating events like birthday and vacations, christmas and thanksgiving, etc. 

Family Tree Tab: shows the family tree as downloaded from FamilySearch.org via gedcom files. It has the merge of the Hudson and Breen family trees, allows for notes, research, and much more. I can fill in more here as needed...

Hallie: Is a way to query the database and get audio feedback. the idea is to be an agentic interfacte to the family tree and catalog. The agent is modeled on an archive librarian and in this case, Hallie is my great grandmother and her avatar is based on restored photos of her. Tha family archivist avatar can be changed but currently Hallie has been worked out pretty well and is the defalult. Hallie primarily responds to family tree questions and finds videos in the archive and catalog. 

1.1 Media 
The app is focused on the Breen family multimedia from 1940s-present. It facilitates the ingestion of media, analyzes the media, and manages the media, assisting the user in archiving important recordings of events like birthdays, holidays, vacations, and other special family events. 

1.2 Archive
The archive holds media deemed important enough to be stored robustly in a RAID with the intention of making it available for future generations. Imagine a great grandaughter looking at her grand grandfather from the 1980s in the year 2065 or something. This is for them, in many ways.

1.3 Family Tree
Holds the family tree and assists the user in researching members, bookmarking, looking at maps, biograhpical info, documents, birth certs, death certs, marriage certs, and allows for agentic or crawling of website such as archives for that person's location, say North Carolina in 1880s. Unique and important historic events are looked for by the app and, like event analyzer, we can search automatically and find association like "great great great grampa so-and-so- fought in the revolutionary war in America".

2. Workflow UI/UX 
The essential workflow for media is: INGEST -> MANAGE -> ARCHIVE
 The app helps the user identify the most important recordings so they can be archived to the most reliable storage which includes 1. RAID 2. Cloud 3. Offsite. This app facilitates and helps the user identify important family events and makes sure the best or master copy is copied to the RAID. The app does also ask / suggest user make a copy for the cloud and offsite but these are currently outside the scope of control of this app.

2.1 Database 
The underlying database is sqlite. the code must be rock solid and all best practices followed. Tests for corner cases and boundary cases must exist and be part of the automated testbed run overnight.

2.2 Agentic and Automated Event and Provenance Discovery
The app assists in analyzing, curating, estimating dates, people, events, and provenance, but the user must confirm. Any new media coming in should have a provenance gate that requests important provanance information which should be stored with that media. The app can try to retroactively create machine generated guesses at provanance but this must be called out as machin egernated needing human confirmation, but the machine has access to lots of metadata and compute power etc., to help the user with such.


3. Process
We use best-in-class and best practices for everything we do, within reason. We don't quite go to the extremes of a medical device which needs FDA approval, but we do follow strict process that detects bugs early, ensures we have tests, and we have gates such as code reviews to keep the code healthy. 

3.1 Testing
We use unit tests and expect code to be testable. We are focused on our code not the supporting framwork. We use code coverage analysis tools and the highest possible settings of the compiler to check the code. We use static analysis and any swift-lint tools, we also measure code complexity and plot how each module is doing, providing it with a grade A-D. We do not allow F to make it to the repo.


3.2 Metrics
We have a series of best-in-class metrics and an associated web page where we plot our progress. See the metrics page.

3.3 Automation
We use as much automation as possible for testing. Any bug has a regression test which can demonstrate the failure before an after fix using red/green approach. 


