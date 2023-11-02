#
# StartTask.ps1  - Dima Etkin, Attunity, Apr-2019
# To get help use the powershell get-help command as shown in th example below
#      get-help .\StartTask_v2.8.ps1
# 
# +---------------------------------------------------------------------------------------------
# | !!!!!! Remember to change the version numbers in the MAIN body !!!!!!!
# +---------------------------------------------------------------------------------------------
# 
# Changes log / Version Control
# +-----+-------------+------------+------------------------------------------------------------
# | Ver | date        | Updated By | Comment
# +-----+-------------+------------+------------------------------------------------------------
# | V1.5| 02-May-2019 | Dima Etkin | Receive clear text password instead of the Credentials object
# |     |             |            | Remove $AemURL, $AemCredential and $AemCredentialFileName parameters
# | V1.6| 03-May-2019 | Dima Etkin | Added "FULL_LOAD_ONLY_FINISHED" to a normal task end reason
# | V1.7| 20-May-2019 | Dima Etkin | Password with spec. chars + ignore ERROR servers
# | V1.8| 23-May-2019 | Dima Etkin | GetServerName returns wrong server name 
# | V1.A| 27-May-2019 | Dima Etkin | Add 10 sec sleeps between the commands to allow AEM sync its internal statuses.
# | V1.B| 27-May-2019 | Dima Etkin | swapped complex -and/-or logic with simple -iin/-inotin and 
# |     |             |            | fixed another bug while there
# | V1.C| 12-Sep-2019 | Dima Etkin | V6.4.0.515 - GetTaskDetails returns a structure without Task header. All 
# |     |             |            | references to the variables had to be adjusted
# | V2.0| 12-Sep-2019 | Dima Etkin | AEM V6.4.0.515 - Start Compose task from the script using new interfaces 
# | V2.1| 01-Oct-2019 | Dima Etkin | Add 2 switches (-Replicate and -Compose) and simplify the overall script logic
# | V2.2| 02-Oct-2019 | Dima Etkin | Added loads more of Verbosemessages as well as changed version sequencing.  
# | V2.3| 03-Oct-2019 | Dima Etkin | Further code enhancements and cleanup
# | V2.4| 04-Oct-2019 | Dima Etkin | Attempt to fix the wrong server name returning from GetServerName. 
# | V2.6| 09-Oct-2019 | Dima Etkin | Fixed the task start for Compose tasks
# |     |             |            | !!!!!!!!!!!!! IMPORTANT !!!!!!!!!!!!!!!
# |     |             |            | Currently GetTaskList and GetTaskDetails do not return the server name, hence there is 
# |     |             |            | no possibility to validate a task or find the correct Project for it. Project has to be specified.
# |     |             |            | Once GetTaskList and GetTaskDetails will be enhanced, more flxibility could be allowed in the 
# |     |             |            | task execution parameters.
# | V2.7| 10-Dec-2019 | Dima Etkin | Added table FL counter comparison to identify tasks with tables in error.
# | V2.8| 31-Oct-2023 | Dima Etkin | Added help comments, reshuffled the parameters
# +-----+-------------+------------+------------------------------------------------------------

<#
.Description
StartTask_x.x.ps1 script allows to start either a Qlik Replicate or Qlik Compose task via QEM APIs.
When starting a replicate task, the script will issue a Start_Task API command and will wait until the task is successfully started. Once the task is started, the script will confirm whether all of the tables are successfully replicating. 

Currently the script is written to start the task in a FULL LOAD mode and wait untill the task completes it's execution. 

Switches :
-Replicate - indicates that the script will start a Replicate task
-Compose   - indicates that the script will start a Compose task

Parameters for Replicate Task:
-QemServer      (M) - DNS of the QEM server
-QemUserName    (O) - QEM Server Login. The userID should have the ADMIN permissions. If no user specified, the userID running the script will be taken as default
-QemPassword    (O) - QEM UserID Password in open text (not very secure, but "we are where we are"
-TaskName       (M) - Replicate Task Name to be started
-TaskServerName (M) - Replicate Server name the task resides on
-StartOption    (M) - RELOAD_TARGET - Run Task with Reload Option
                      RESUME_PROCESSING - Rrun task in Resume mode 
 
 ------- Compose Task Only
-TaskProject    (M) - Project Name where the task resides
 
 (M)/(O) - Mandatory/Optional

.Example
./StartTask.ps1 -Replicate -QemServer localhost -QemUserName domain/userid -QemPassword abracadabra -TaskName MyTask -TaskServerName LocalServer
#> 


[CmdletBinding(DefaultParameterSetName='ReplicateTaskConfig')]
param(
     # Replicate Task parameters
     [Parameter(Mandatory=$True, ParameterSetName='ReplicateTaskConfig')]
        [Switch] $Replicate
     # Compose Task parameters
    ,[Parameter(Mandatory=$True, ParameterSetName='ComposeTaskConfig')]
        [Switch] $Compose
    ,[Parameter(Mandatory=$true)] [string] $QemServer = 'localhost'
    ,[Parameter(Mandatory=$false)] [string] $QemUserName = $env:UserDomain + '\' + $env:UserName
    ,[Parameter(Mandatory=$true)] [string] $QemPassword = ''
    ,[Parameter(Mandatory=$true)] [string] $TaskServerName = ''      
	,[Parameter(Mandatory=$true)] [string] $TaskName = ''        #TaskName for each task
	,[Parameter(Mandatory=$true, ParameterSetName='ReplicateTaskConfig')] [validateset("RELOAD_TARGET","RESUME_PROCESSING")] [string] $StartOption
    ,[Parameter(Mandatory=$true, ParameterSetName='ComposeTaskConfig')]
     [string] $TaskProject 
)



function RunAttunityTask {
    param (
        [Parameter(Mandatory=$true, Position=0)]  [Attunity.Aem.RestClient.AemRestClient] $AemConnection
       ,[Parameter(Mandatory=$true, Position=1)]  [String]                                $TaskServerName
       ,[Parameter(Mandatory=$true, Position=2)]  [String]                                $TaskName
       ,[Parameter(Mandatory=$true, Position=3)]  [String]                                $StartOption
       ,[Parameter(Mandatory=$true, Position=4)]  [Int32]                                 $CommandTimeout
       ,[Parameter(Mandatory=$true, Position=5)]  [String]                                $TaskType
       ,[Parameter(Mandatory=$False,Position=6)]  [String]                                $TaskProject
    )

    try {
        Write-Verbose ($MyInvocation.InvocationName + ' Set Local Constants')
        $AEM_SYNC_TIMEOUT = 30
        # -----------------------------------------------------------------------------------
        # Set Start Task variable and start the task
        # -----------------------------------------------------------------------------------
        Write-Verbose ($MyInvocation.InvocationName + ' Setting Start Task Request and Options variables')
        $AemRunTaskReq        = New-Object Attunity.Aem.RestClient.Models.AemRunTaskReq
        $AemRunTaskOption     = New-Object Attunity.Aem.RestClient.Models.AemRunTaskOptions
        
        
        Write-Verbose ($MyInvocation.InvocationName + ' Get initial task state')
        $TaskDetails = $AemConnection.GetTaskDetails($TaskServerName,$TaskName)
        $TaskState   = $TaskDetails.State
        $TaskName    = $TaskDetails.Name # Set the name as it appears in the solution, as if the task name is 
                                         # incorrect, replicate will get stuck in a retry logic loop.
        Write-Verbose ($MyInvocation.InvocationName + ' Initial TaskState is: ' + $TaskDetails.State)

        if ($TaskState -inotin "STOPPED","ERROR") {
            Write-Verbose ($MyInvocation.InvocationName + ' Inconsistent initial Task State ' + $TaskState)
            throw "Can't start the task which is in $TaskState state. Please stop the task manually and retry"
        }

        # Run the replicate task
        Write-Verbose ($MyInvocation.InvocationName + ' Execute task with following parameters: ' + $TaskServerName + ' ' + $TaskName + ' ' + $AemRunTaskOption::$StartOption + ' ' + $CommandTimeout)
        $TaskRun     = $AemConnection.RunTask( $AemRunTaskReq, $TaskServerName, $TaskName, $AemRunTaskOption::$StartOption, $CommandTimeout)
        # Write-Host ("TaskRun API call completed with """, $TaskRun.State ,""" state and Message """, $TaskRun.ErrorMessage, """") -Separator ""
        Write-Verbose ($MyInvocation.InvocationName + ' After Task Execution - State:' + $TaskRun.State + ' Message:' + $TaskRun.ErrorMessage)
        
        # !!!! For Future !!!!
        # --------------------------
        # Review the complexity below once the AEM defect affecting timely statuses propagation between the products will have been fixed
        #   and the statuses are propagated in timely manner from the worker server to AEM 
        # --------------------------

        # Sleep for some time to ensure that the statuses are in sync and then get the task details again 
        if ($TaskRun.State -inotin "ERROR", "RECOVERY") {
            Write-Verbose ($MyInvocation.InvocationName + ' Sleep for ' +$AEM_SYNC_TIMEOUT+ ' seconds to sync AEM statuses')
            sleep $AEM_SYNC_TIMEOUT
            
            Write-Verbose ($MyInvocation.InvocationName + ' Get task details before starting the wait loop')
            $TaskDetails = $AemConnection.GetTaskDetails($TaskServerName,$TaskName)
            Write-Verbose ($MyInvocation.InvocationName + ' Task State before entering the wait loop is ' + $TaskDetails.State)
            
            # Wait until the task completes
            Write-Verbose ($MyInvocation.InvocationName + ' Wait looping till the task completes')
            $Counter = 0
            while ( $TaskDetails.State -ieq "RUNNING" ) {
                if ($Counter % 100 -eq 0) {
                    write-host ("")
                    $CurrentDateTime = get-date -Format s
                    Write-host ($CurrentDateTime, $TaskDetails.State) -NoNewline -Separator " "
                } ELSE {
                    Write-host (".") -NoNewline
                }
                Write-Verbose ($MyInvocation.InvocationName + ' In the loop, sleep for 5 seconds')
                sleep 5
                $TaskDetails = $AemConnection.GetTaskDetails($TaskServerName,$TaskName)
                Write-Verbose ($MyInvocation.InvocationName + ' In the loop - get task details ' + $TaskDetails.State)
                $Counter++
                Write-Verbose ($MyInvocation.InvocationName + ' Increment loop counter to ' + $Counter)
            }
        }
        # Sleep some time to allow AEM to sincronize internal statuses.
        Write-Verbose ($MyInvocation.InvocationName + ' Sleep for ' +$AEM_SYNC_TIMEOUT+ ' seconds to sync AEM statuses')
        sleep $AEM_SYNC_TIMEOUT

        # Interpret task Stop Reason and Error message
        Write-Verbose ($MyInvocation.InvocationName + ' Wake up and get final task state and reason')
        $TaskDetails  = $AemConnection.GetTaskDetails($TaskServerName,$TaskName)
        Write-Verbose ($MyInvocation.InvocationName + ' Final task State:' + $TaskDetails.State + ', Reason:' + $TaskDetails.TaskStopReason)

        write-host ("")
        Write-host ("Task """+$TaskName+""" finished with status """+$TaskDetails.State+""" with reason """+$TaskDetails.TaskStopReason+"""")

        # Error handling logic
        Write-Verbose ($MyInvocation.InvocationName + ' Start error handling logic')
        switch($TaskDetails.GetType().Name) {
            #--------------------------------------------------------
            # Analize the result of Replicate Task
            #--------------------------------------------------------
            "AemReplicateTaskInfoDetailed" {
                switch($TaskDetails.State) {
                    "STOPPED" {
                        if ($TaskDetails.TaskStopReason -inotin "NONE","NORMAL","FULL_LOAD_ONLY_FINISHED") {
                            Write-Verbose ($MyInvocation.InvocationName + ' Unexpected Stop Reason "' + $TaskDetails.TaskStopReason + '" for the task "' + $TaskDetails.Name + '"')
                            if ($TaskDetails.Message) {throw $TaskDetails.Message} 
                        }
                        elseif ($TaskDetails.FullLoadCompleted) {
                            Write-host ("Replicate Task """+$TaskName+""" finished at "+$TaskDetails.FullLoadEnd) 
                            Write-host ("Tables Completed : "+$TaskDetails.FullLoadCounters.TablesCompletedCount) 
                            Write-host ("Tables Loading   : "+$TaskDetails.FullLoadCounters.TablesLoadingCount) 
                            Write-host ("Tables Queued    : "+$TaskDetails.FullLoadCounters.TablesQueuedCount)  
                            Write-host ("Tables with Error: "+$TaskDetails.FullLoadCounters.TablesWithErrorCount)
                            Write-Verbose ("Determining whether any tables were not successfully loaded.")
                            if (($TaskDetails.FullLoadCounters.TablesLoadingCount -ne 0) -or
                                ($TaskDetails.FullLoadCounters.TablesQueuedCount -ne 0) -or
                                ($TaskDetails.FullLoadCounters.TablesWithErrorCount -ne 0)) {
                                    Write-host ("Not all tables have been successfully loaded. Terminating task") 
                                    exit $CODE_ERROR
                                }
                            else {
                                exit $CODE_OK
                            }
                        }
                    }
                    default {
                        Write-Verbose ($MyInvocation.InvocationName + ' Unexpected Task State "' + $TaskDetails.State + '" for the task "' + $TaskDetails.Name + '"')
                        if ($TaskDetails.Message) {throw $TaskDetails.Message} 
                    }
                }
            }
            #--------------------------------------------------------
            # Analize the result of Compose Task
            #--------------------------------------------------------
            "AemComposeTaskInfoDetailed" {
                switch($TaskDetails.State) {
                    "STOPPED" {
                        if (-not $TaskDetails.LoadingCompleted) {
                            $Message = $MyInvocation.InvocationName + ' Task "' + $TaskDetails.Name +'" in project "'+$TaskDetails.Project+'" Was stopped but not completed.'
                            Write-Verbose ($Message)
                            if ($TaskDetails.Message) {throw $TaskDetails.Message} else {throw $Message}
                        }
                        else {
                            Write-host ("Compose Task """+ $TaskDetails.Name +""" in project """+$TaskDetails.Project+""" finished.")
                            Write-host ("Tables Total Count : "+$TaskDetails.LoadingCounters.TablesTotalCount) 
                            Write-host ("Tables Completed   : "+$TaskDetails.LoadingCounters.TablesCompletedCount) 
                            Write-host ("Tables Loading     : "+$TaskDetails.LoadingCounters.TablesLoadingCount) 
                            Write-host ("Tables Queued      : "+$TaskDetails.LoadingCounters.TablesQueuedCount)  
                            Write-host ("Tables with Error  : "+$TaskDetails.LoadingCounters.TablesWithErrorCount)
                            Write-Verbose ("Determining whether any tables were not successfully loaded.")
                            if ($TaskDetails.LoadingCounters.TablesTotalCount -ne $TaskDetails.LoadingCounters.TablesCompletedCount) {
                                    Write-host ("Not all tables have been loaded ("+$TaskDetails.LoadingCounters.TablesCompletedCount+" out of "+$TaskDetails.LoadingCounters.TablesTotalCount+"). Terminating task") 
                                    exit $CODE_ERROR
                                }
                            else {
                                exit $CODE_OK
                            }
                        }
                    }
                    default {
                        $Message = $MyInvocation.InvocationName + ' Inconsistent State "'+$TaskDetails.State+'" for task "'+$TaskDetails.Name+'" in project "'+$TaskDetails.Project+'".'
                        Write-Verbose ($Message)
                        if ($TaskDetails.Message) {throw $TaskDetails.Message} else {throw $Message}
                    }
                }
            }
        }
    }
    Catch {
        Write-host ("Something went wrong while Starting the task")
        Write-host ("  Category   : ",$_.CategoryInfo.Category) -Separator " "
        Write-host ("  Exception  : ",$_.Exception) -Separator " "
        Write-host ("  Stack Trace: ",$_.ScriptStackTrace) -Separator " "
        exit $CODE_ERROR
    }
        
}

<#-----------------------------------------------------------------------------------
  - Function: ValidateServer
  - Input   : AemConnection [Attunity.Aem.RestClient.AemRestClient] - connection token
            : TaskName [String]                 - Name of AEM DLL to Load
  - Output  : [String]                          - Server Name 
  - Description:
  - ------------
  - If function returns the Server Name for the task, if found on a single server attached to AEM
  
   # Changes log
  ------------+------------+------------------------------------------------------------
  Date        | Updated By | Comment
  ------------+------------+------------------------------------------------------------
  20-May-2019 | Dima Etkin | Added logic to avoid querying servers that are either not 
                           | monitored or in ERROR to ensure the loop does not abend when 
                           | Requesting specific server details. 
  23-May-2019 | Dima Etkin | Wrong server could be returned by the procedure.  
  ------------+------------+------------------------------------------------------------
  -----------------------------------------------------------------------------------#>
function ValidateServer {
    param (
        [Parameter(Mandatory=$true,  Position=0)]     [Attunity.Aem.RestClient.AemRestClient] $AemConnection
       ,[Parameter(Mandatory=$true,  Position=1)]     [String] $TaskName
       ,[Parameter(Mandatory=$false, Position=2)]     [String] $TaskServerName
       ,[Parameter(Mandatory=$false, Position=3)]     [String] $TaskType
       ,[Parameter(Mandatory=$false, Position=4)]     [String] $TaskProject
    )

    try {
     
        Write-Verbose ($MyInvocation.InvocationName + ' Define local variables')
        $Server = [PSObject]$SERVER_PROPERTIES

        Write-Verbose ($MyInvocation.InvocationName + " Validate TaskServer variable ""$TaskServerName""")
        if (-not $TaskServerName) {
            Write-host ("""-TaskServer"" parameter has not been specified. Looking for a server to run task ""$TaskName""")
            Write-Verbose ($MyInvocation.InvocationName + ' Call GetServerName')
            $Server = GetServerName $client $TaskName $TaskProject $TaskType
            Write-Verbose ($MyInvocation.InvocationName + ' GetServerName returned ' + $Server.Name +' '+ $Server.Type)
        }
        else {
            Write-Verbose ($MyInvocation.InvocationName + ' Check Server Type')
            switch ($AemConnection.GetServerDetails($TaskServerName).ServerDetails.GetType().Name) {
                "ReplicateServerDetails" {$Server.Type = "REPLICATE"; break; } 
                "ComposeServerDetails"   {$Server.Type = "COMPOSE"  ; break; }
            }
            Write-Verbose ($MyInvocation.InvocationName + ' Server type is ' + $Server.Type)

            if ($Server.Type -ine $TaskType) {
                Write-Verbose ($MyInvocation.InvocationName + ' Wrong server type')
                throw "The specified server type """+$TaskType+"""is different from the actual server type """+$ServerDetailsType+""""
            }
            Write-Verbose ($MyInvocation.InvocationName + ' Initialise return structure.')
            $Server.Name = $TaskServerName
        }

        Write-Verbose ($MyInvocation.InvocationName + ' Return Server Structure.')
        Return $Server
    }
    catch {
        Write-host ("Something went wrong while looking for a server")
        Write-host ("  Category   : ",$_.CategoryInfo.Category) -Separator " "
        Write-host ("  Exception  : ",$_.Exception) -Separator " "
        Write-host ("  Stack Trace: ",$_.ScriptStackTrace) -Separator " "
        exit $CODE_ERROR
    }
}

<#-----------------------------------------------------------------------------------
  - Function: GetServerName
  - Input   : AemConnection [Attunity.Aem.RestClient.AemRestClient] - connection token
            : TaskName [String]                 - Name of AEM DLL to Load
  - Output  : [String]                          - Server Name 
  - Description:
  - ------------
  - If function returns the Server Name for the task, if found on a single server attached to AEM
  
   # Changes log
  ------------+------------+------------------------------------------------------------
  Date        | Updated By | Comment
  ------------+------------+------------------------------------------------------------
  20-May-2019 | Dima Etkin | Added logic to avoid querying servers that are either not 
                           | monitored or in ERROR to ensure the loop does not abend when 
                           | Requesting specific server details. 
  23-May-2019 | Dima Etkin | Wrong server could be returned by the procedure.  
  ------------+------------+------------------------------------------------------------
  -----------------------------------------------------------------------------------#>
function GetServerName {
    param (
        [Parameter(Mandatory=$true, Position=0)]        [Attunity.Aem.RestClient.AemRestClient] $AemConnection
       ,[Parameter(Mandatory=$true, Position=1)]        [String] $TaskName
       ,[Parameter(Mandatory=$False,Position=2)]        [String] $TaskProject
       ,[Parameter(Mandatory=$true, Position=3)]        [String] $TaskType

    )

    try {

        Write-Verbose ($MyInvocation.InvocationName + ' Define local variables')
        $TempServer   = [PSObject]$SERVER_PROPERTIES

        $TaskFound     = $false
        $TaskSearchCounter = 0

        # -----------------------------------------------------------------------------------
        # - Search for the task on every server connected to AEM
        # -----------------------------------------------------------------------------------
        Write-Verbose ($MyInvocation.InvocationName + ' Validate each server in the list')
        foreach ($ServerElement in $AemConnection.GetServerList().ServerList) {
            $TaskFound          = $false
            $ServerQualified    = $True
            $TempServer.Name    = $ServerElement.Name
            $TempServer.State   = $ServerElement.State  
            $TempServer.Message = $ServerElement.Message
            switch ($AemConnection.GetServerDetails($ServerElement.Name).ServerDetails.GetType().Name) {
                "ReplicateServerDetails" {$TempServer.Type = "REPLICATE"; break; } 
                "ComposeServerDetails"   {$TempServer.Type = "COMPOSE"  ; break; }
            }
            Write-Verbose ($MyInvocation.InvocationName + ' Trying Server - Name:' + $TempServer.Name + ' Type:' + $TempServer.Type + ' State:' + $TempServer.State + ' Message:' + $TempServer.Message)

            # ---------------------- !!!!! IMPORTANT !!!!! ------------------------------
            # This IF is a workaround for the lack of support for Compose tasks API.
            # Once API is enhanced, this logic will need to be reviewed
            # $Server.Type can have the following value:
            #     ReplicateServerDetails - for Replicate Server 
            #     ComposeServerDetails   - for compose server
            # ---------------------- !!!!! IMPORTANT !!!!! ------------------------------
            if (($TempServer.State -ieq 'MONITORED') -and ($TempServer.Type -ieq $TaskType ))  {
                 foreach ($Task in $AemConnection.GetTaskList($TempServer.Name).TaskList) { 
                     if ($Task.Name -ieq $TaskName) {                           
                         Write-Verbose ($MyInvocation.InvocationName + ' Task "' + $TaskName + '" found on server "' + $TempServer.Name + '"')
                         $ReturnServer = $TempServer.clone() #Instantiate a new value rather than referencing the $Serer variable
                         $TaskFound    = $true
                         $TaskSearchCounter++
                     }
                 }
             }

            elseif (-not ($TempServer.State -ieq 'MONITORED')) {
                Write-Verbose ($MyInvocation.InvocationName + ' Server "'+$TempServer.Name+'" ignored as it is in "'+$TempServer.State+'" state with a message "'+$TempServer.Message+'"')
                $ServerQualified = $false
            }
            elseif (-not ($TempServer.Type -ieq $TaskType)) {
                Write-Verbose ($MyInvocation.InvocationName + ' Server "'+$TempServer.Name+'" ignored as it is a "'+$TempServer.Type+'" Server')
                $ServerQualified = $false
            }

            
            if ($ServerQualified -and (-not $TaskFound)) {
                Write-Host ($MyInvocation.InvocationName + ' No tasks called "' + $TaskName + '" found on server "' + $TempServer.Name + '"')
            }
            elseif (-not $ServerQualified) {
                Write-Host ($MyInvocation.InvocationName + ' Server "' + $TempServer.Name + '" does not qualify')
            }
        }
        
        # -----------------------------------------------------------------------------------
        # - Make sure that the script can continue.        
        # - it will continue only is a unique task has been found on the AEM server
        # -----------------------------------------------------------------------------------
        Write-Verbose ($MyInvocation.InvocationName + ' Total of ' + $TaskSearchCounter + ' task(s) found on active ' + $TaskType + ' servers')
        switch($TaskSearchCounter) {
            0 {
                throw ("Task ""$TaskName"" can't be found on any server attached to ""$QemServer"" AEM Server. Please correct the Task Name and try again.")
            }
            1 {
                Write-host ("Task """+$TaskName+""" found on a single server """+$ReturnServer.Name+"""")
            }
            Default {
                throw ("Task ""$TaskName"" found on multiple servers. Either Specify ""-TaskServer"" parameter or make sure the Task Name is unique in ""$QemServer"" AEM Server")
            }
        }

        Write-Verbose ($MyInvocation.InvocationName + ' Returning server - Name:' + $ReturnServer.Name + ' Type:' + $ReturnServer.Type + ' State:' + $ReturnServer.State + ' Message:' + $ReturnServer.Message)
        Return $ReturnServer
    }
    catch {
        Write-host ("Something went wrong while looking for a server")
        Write-host ("  Category   : ",$_.CategoryInfo.Category) -Separator " "
        Write-host ("  Exception  : ",$_.Exception) -Separator " "
        Write-host ("  Stack Trace: ",$_.ScriptStackTrace) -Separator " "
        exit $CODE_ERROR
    }
}


<#-----------------------------------------------------------------------------------
  - Function: Import_AEM_DLL
  - Input   : DllName [String]                 - Name of AEM DLL to Load
  - Output  : N/A 
  - Description:
  - ------------
  - Looks for a DLL in a local folder or in AEM install path and loads the instance that
  - has been found.
  -----------------------------------------------------------------------------------#>
function Import_AEM_DLL {
    param (
        [Parameter(Mandatory=$true,  Position=0)]  [String] $DllName
    )

    try {
        # -----------------------------------------------------------------------------------
        # Try looking for the DLL in the Current Directory or in the Script execution directory
        # -----------------------------------------------------------------------------------
        Write-Verbose ($MyInvocation.InvocationName + ' Set DLL files full path')
        if ($PSScriptRoot) { 
            $FileFullPath = $PSScriptRoot + '\' + $DllName 
        } 
        else { 
            $FileFullPath = '.\' + $DllName 
        }
        Write-Verbose ($MyInvocation.InvocationName + ' DLL files full path is set to ' + $FileFullPath)
        
        if (-not (Test-Path $FileFullPath)) {
           # -----------------------------------------------------------------------------------
           # Not next to script, let's hope the AME is local and find its install location.
           # -----------------------------------------------------------------------------------
           if (-not $Root ) {
                 Write-Verbose ($MyInvocation.InvocationName + ' DLL files were not found locally. Get the HKLM\SOFTWARE\Attunity\Enterprise Manager content ')
                 $AemRegistryEntry = Get-ItemProperty -Path "Registry::HKLM\SOFTWARE\Attunity\Enterprise Manager" -name "RootDir"
                 $AemRootDir = $AemRegistryEntry.RootDir
                 if (-not $AemRootDir) {
                     throw "-- Did NOT find $DllName in $PSScriptRoot, and could NOT establish AEM Root Directory"
                 }
               
                $FileFullPath = $AemRootDir + 'clients\dotnet\' + $DllName
                if (-not (Test-Path $FileFullPath)) {
                    throw "-- Did NOT find $DllName in $PSScriptRoot NOR in AEM Root Directory"
                }
           }
        }
        
        Import-Module $FileFullPath -ErrorAction Stop
        Write-host ("AEM DLL ""$DllName"" imported from ""$FileFullPath""")
    }
    catch {
        Write-host ("Something went wrong while loading DLLs")
        Write-host ("  Category   : ",$_.CategoryInfo.Category) -Separator " "
        Write-host ("  Exception  : ",$_.Exception) -Separator " "
        Write-host ("  Stack Trace: ",$_.ScriptStackTrace) -Separator " "
        exit $CODE_ERROR
    }
}


<#-----------------------------------------------------------------------------------
  - Function: SetAemCredentials
  - Input   : UserID [String]                  - User ID with Domain (dmn\user)
  -           QemPassword [String]             - Password in Clear Text
  - Output  : [System.Management.Automation.PSCredential] - credentials type object 
  - Description:
  - ------------
  - Use if provided in global variable, or grab from file if that is provided, or prompt.
  - Stash away for re-use if credential file is provided. Provide empty string to avoid this.
  -
   # Changes log
  ------------+------------+------------------------------------------------------------
  Date        | Updated By | Comment
  ------------+------------+------------------------------------------------------------
  20-May-2019 | Dima Etkin | Added logic to ensure that if a password contains special cha-
                           | racters it will still be processed corrctly. 
  ------------+------------+------------------------------------------------------------
  -----------------------------------------------------------------------------------#>
function SetAemCredentials {
    [OutputType([System.Management.Automation.PSCredential])]
    param ( 
        [Parameter(Mandatory=$true,  Position=0)]           [String] $QemUserName 
       ,[Parameter(Mandatory=$true,  Position=1)]           [String] $QemPassword
    )

    try {
        Write-Verbose ($MyInvocation.InvocationName + ' Deal with credentials')
        if (-not $QemPassword) {  # No password was supplied. 
            Write-Verbose ($MyInvocation.InvocationName + ' No Password was supplied')
            throw "No password was supplied. Exiting script with error"
        }
        else {
            Write-Verbose ($MyInvocation.InvocationName + ' Password supplied, try to establish credentials')
            $password = ConvertTo-SecureString -string "$QemPassword" -asplaintext -force 
            Get-Variable QemPassword | Remove-Variable -force
            $AemCredential = New-Object System.Management.Automation.PSCredential($QemUserName,$password)
        }

        
        if ( -not $AemCredential ) { # Still no credential? throw an error
            Write-Verbose ($MyInvocation.InvocationName + ' Credentials were not generated')
            throw "No Credentials were generated. Exiting script with error"
        }
        
        Write-Verbose ($MyInvocation.InvocationName + ' Return established credentials')
        return $AemCredential
    }
    catch {
        Write-host ("Something went wrong in the get credentials")
        Write-host ("  Category   : ",$_.CategoryInfo.Category) -Separator " "
        Write-host ("  Exception  : ",$_.Exception) -Separator " "
        Write-host ("  Stack Trace: ",$_.ScriptStackTrace) -Separator " "
        exit $CODE_ERROR
    }
}


<#-----------------------------------------------------------------------------------
  -----------------------------------------------------------------------------------
  --------------------------------------- M A I N -----------------------------------
  -----------------------------------------------------------------------------------
  -----------------------------------------------------------------------------------#>
Clear 

try {
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Define Global Constants and Data Types')
    # -----------------------------------------------------------------------------------
    # Set GLOBAL Constants 
    # -----------------------------------------------------------------------------------
    # Version Information
    $SCRIPT_VERSION   = '2'
    $SCRIPT_MINOR     = '8'
    # Return Codes
    $CODE_ERROR       = 1
    $CODE_OK          = 0
    # Run Task options ----------
    $RELOAD_TARGET    = 'RELOAD_TARGET'          # Run Task option 
	$RESUME_TASK      = 'RESUME_PROCESSING'
    $NONE             = 'NONE'
    # Other constants
    $COMMAND_TIMEOUT  = 120                      # Run Task command timeout
    # Create ServerProperties type 
    $SERVER_PROPERTIES = @{
       Name = ''
       Type = ''
       State = ''
       Message = ''
    }

    # -----------------------------------------------------------------------------------
    # Set local variables 
    # -----------------------------------------------------------------------------------
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Define local variables')
    $Server = [PSObject]$SERVER_PROPERTIES

    Write-host ("Start Task script Version "+$SCRIPT_VERSION+"."+$SCRIPT_MINOR)
    
    # !!!!! Note for self - Try to set the timeout to 0 in order to simplify the script.
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Set Session certificate/TLS overrides')
    # -----------------------------------------------------------------------------------
    # Session Security Settings
    # -----------------------------------------------------------------------------------
    # Force the connection to use TLS V1.2 
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    
    # Ignore Certificates validation
    [system.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true} 
    
    # -----------------------------------------------------------------------------------
    # Validate switches
    # -----------------------------------------------------------------------------------
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Validate Switches' + $Replicate + $Compose)
    if ($Replicate -xor $Compose) {
        if      ($Replicate) {
            $TaskType = "REPLICATE"
        }
        elseif  ($Compose)   {
            $TaskType = "COMPOSE"
        }
    } 
    ELSE {
        throw "Either ""-Replicate"" or ""-Compose"" switch has to be specified"
    }
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Switches indicate that the task type is ' + $TaskType)
    
    # -----------------------------------------------------------------------------------
    # Load credentials
    # -----------------------------------------------------------------------------------
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Generate Credentials object')
    if ($QemPassword) {
        $AemCredential = SetAemCredentials $QemUserName $QemPassword 
        Get-Variable QemPassword | Remove-Variable -force
    } 
    else {
        throw "Empty password string. Please populate the requiered parameter."
    }
    
    # -----------------------------------------------------------------------------------
    # Load AEM dlls
    # -----------------------------------------------------------------------------------
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Import DLLs')
    Import_AEM_Dll ('AemRestClient.dll')
    
    # -----------------------------------------------------------------------------------
    # - Connect!
    # -----------------------------------------------------------------------------------
    $AemURL = "https://" + $QemServer + "/attunityenterprisemanager"
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - URL generated as ' + $AemURL)
    $client = New-Object Attunity.Aem.RestClient.AemRestClient($AemCredential, $AemURL, $false) 
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Connection generated with token ' + $client.ToString())
    
    # -----------------------------------------------------------------------------------
    # - Validate the Server/ServerType/TaskType
    # -----------------------------------------------------------------------------------
    $Server = ValidateServer $client $TaskName $TaskServerName $TaskType $TaskProject
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Received Server - Name:' + $Server.Name + ' Type:' + $Server.Type + ' State:' + $Server.State + ' Message:' + $Server.Message)

        
    # -----------------------------------------------------------------------------------
    # Run the task
    # -----------------------------------------------------------------------------------
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Set Run Option')
    switch ($Server.Type) {
      "REPLICATE" {$StartOption}
      "COMPOSE" {$StartOption = $NONE}
      default {$StartOption = $NONE}
    }
    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Run Option for this task is ' + $StartOption)

    Write-Verbose ($MyInvocation.InvocationName + ' MAIN - Run the task')
    RunAttunityTask $client $Server.Name $TaskName $StartOption $COMMAND_TIMEOUT $Server.Type #$TaskProject
}
catch {
    Write-host ("Something went wrong in the main processing logic")
    Write-host ("  Category   : ",$_.CategoryInfo.Category) -Separator " "
    Write-host ("  Exception  : ",$_.Exception) -Separator " "
    Write-host ("  Stack Trace: ",$_.ScriptStackTrace) -Separator " "
    exit $CODE_ERROR
}
<#-----------------------------------------------------------------------------------
  -----------------------------------------------------------------------------------
  ---------------------------- E N D ------ M A I N ---------------------------------
  -----------------------------------------------------------------------------------
  -----------------------------------------------------------------------------------#> 