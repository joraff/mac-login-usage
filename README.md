**Unmaintained since 2011**

Login and Application Usage capture system

Client Files:
 - edu.baylor.gatherLoginData.plist: LaunchAgent that starts gather_login_data.rb
 - edu.baylor.processLoginData.plist: LaunchDaemon that runs process_login_data.rb - gather_login_data.rb: starts the sessions data recording at a user login
 - process_login_data.rb: processes leftover session data at startup (like from a power loss)
 - Usage.rb: class that has all the good stuff

Server Files:
 - edu.baylor.startLoginServer.plist
 - start_login_server.rb: starts the server that listens for packets from the clients
 - UsageServer.rb: class that contains the server code. requires the same Usage.rb as above


Install the LaunchAgent and LaunchDaemon above on the client in the appropriate /Library folders. I like to put most of my maintenance scripts in /usr/local/bin/maint on the clients and make it only readable to root (launchdaemons and launchagents run as root anyways), but they can really go wherever as long as you change the launched plist files. Usage.rb must be in the same folder.

Install the server LaunchDaemon and scripts, tailoring as necessary. The UsageServer.rb will definitely need to be modified with your database information.

The database schema should be as follows: database name doesn't matter, but the table names and columns do. There should be a table called "apps" with the following columns:

	id (int)
	session_id (int)
	duration (int)
	name (varchar)

There should be another table called "logins" with the following columns:

	id (int)
	username (varchar)
	computername (varchar)
	macaddress (varchar)
	ipaddress (varchar)
	logindate (datetime)
	logoutdate (datetime)
	shaname (varchar)
