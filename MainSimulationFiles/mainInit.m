function [appParams,simParams,phyParams,outParams,simValues,outputValues,...
    sinrManagement,timeManagement,positionManagement,stationManagement] = mainInit(appParams,simParams,phyParams,outParams,simValues,outputValues,positionManagement)
% Initialization function

%% Init of active vehicles and states
% Move IDvehicle from simValues to station Management
stationManagement.activeIDs = simValues.IDvehicle;
simValues = rmfield(simValues,'IDvehicle');

% The simulation starts at time '0'
timeManagement.timeNow = 0;

% State of each node
% Discriminates C-V2X nodes from 11p nodes
if simParams.technology==1
    
    % All vehicles in C-V2X (lte or 5g) are currently in the same state
    % 100 = LTE TX/RX
    stationManagement.vehicleState = 100 * ones(simValues.maxID,1);
 
elseif simParams.technology==2
   
    % The possible states in 11p are four:
    % 1 = IDLE :    the node has no packet and senses the medium as free
    % 2 = BACKOFF : the node has a packet to transmit and senses the medium as
    %               free; it is thus performing the backoff
    % 3 = TX :      the node is transmitting
    % 9 = RX :      the node is sensing the medium as busy and possibly receiving
    %               a packet (the sender it firstly sensed is saved in
    %               idFromWhichRx)
    stationManagement.vehicleState = ones(simValues.maxID,1);

else % coexistence
    
    % Init all as LTE
    stationManagement.vehicleState = 100 * ones(simValues.maxID,1);
    %Then use simParams.numVehiclesLTE and simParams.numVehicles11p to
    %initialize
    for i11p = 1:simParams.numVehicles11p
        stationManagement.vehicleState(simParams.numVehiclesLTE+i11p:simParams.numVehiclesLTE+simParams.numVehicles11p:end) = 1;
    end
        
%     % POSSIBLE OPTION FOR DEBUG PURPOSES
%     % First half 11p, Second half LTE
%     stationManagement.vehicleState = 100*ones(simValues.maxID,1);
%     stationManagement.vehicleState(1:1:end/2) = 1;

end

% RSUs technology set
if appParams.nRSUs>0
    if strcmpi(appParams.RSU_technology,'11p')
        stationManagement.vehicleState(end-appParams.nRSUs+1:end) = 1;
    elseif strcmpi(appParams.RSU_technology,'LTE')
        stationManagement.vehicleState(end-appParams.nRSUs+1:end) = 100;
    end
end

%% Initialization of the vectors of active vehicles in each technology, 
% which is helpful to work with smaller vectors and matrixes
stationManagement.activeIDsCV2X = stationManagement.activeIDs.*(stationManagement.vehicleState(stationManagement.activeIDs)==100);
stationManagement.activeIDsCV2X = stationManagement.activeIDsCV2X(stationManagement.activeIDsCV2X>0);
stationManagement.activeIDs11p = stationManagement.activeIDs.*(stationManagement.vehicleState(stationManagement.activeIDs)~=100);
stationManagement.activeIDs11p = stationManagement.activeIDs11p(stationManagement.activeIDs11p>0);
stationManagement.indexInActiveIDs_ofLTEnodes = zeros(length(stationManagement.activeIDsCV2X),1);
for i=1:length(stationManagement.activeIDsCV2X)
    stationManagement.indexInActiveIDs_ofLTEnodes(i) = find(stationManagement.activeIDs==stationManagement.activeIDsCV2X(i));
end
stationManagement.indexInActiveIDs_of11pnodes = zeros(length(stationManagement.activeIDs11p),1);
for i=1:length(stationManagement.activeIDs11p)
    stationManagement.indexInActiveIDs_of11pnodes(i) = find(stationManagement.activeIDs==stationManagement.activeIDs11p(i));
end

%% Number of vehicles at the current time
outputValues.Nvehicles = length(stationManagement.activeIDs);
outputValues.NvehiclesTOT = outputValues.NvehiclesTOT + outputValues.Nvehicles;
outputValues.NvehiclesLTE = outputValues.NvehiclesLTE + length(stationManagement.activeIDsCV2X);
outputValues.Nvehicles11p = outputValues.Nvehicles11p + length(stationManagement.activeIDs11p);

%% Initialization of packets management 
% Number of packets in the queue of each node
stationManagement.pckBuffer = zeros(simValues.maxID,1);
% Type of packets
% 1 = CAM
% 2 = DENM
stationManagement.pckType = 1*ones(simValues.maxID,1);
if appParams.nRSUs>0 && ~strcmpi(appParams.RSU_pckTypeString,'CAM')
    stationManagement.pckType(end-appParams.nRSUs+1:end) = 2;
end
% From v 5.4.14 the following are needed for multiple transmissions 
% 'pckReceived' registers if the current packet has already been received
% pckReceived=1 means already received
% pckReceived=0 means never attempted to decode
% pckReceived=-x means attempted to decode 'x' times 
stationManagement.pckReceived = zeros(simValues.maxID,simValues.maxID); % (TO, FROM)
% cumulative SINR
sinrManagement.cumulativeSINR = zeros(simValues.maxID,simValues.maxID); % (TO, FROM)
% pckRemainingTx counts the remaining transmissions
stationManagement.pckNextAttempt = ones(simValues.maxID,1);
% pckTxOccurring is used in LTE and set at the beginning of the subframe,
% because pckRemainingTx might change during the subframe
stationManagement.pckTxOccurring = zeros(simValues.maxID,1);

% HARQ init
stationManagement.cv2xNumberOfReplicas = phyParams.cv2xNumberOfReplicasMax * ones(simValues.maxID,1);
%%%%%%%

%% Packet generation
timeManagement.timeGeneratedPacketInTxLTE = -1 * ones(simValues.maxID,1);
if appParams.variabilityGenerationInterval==-1
    if simParams.typeOfScenario~=2 % Not traffic trace
        timeManagement.generationIntervalDeterministicPart = generationPeriodFromSpeed(simValues.v,appParams);
    else
        timeManagement.generationIntervalDeterministicPart = appParams.generationInterval * ones(simValues.maxID,1);
    end
else
    timeManagement.generationIntervalDeterministicPart = appParams.generationInterval - appParams.variabilityGenerationInterval/2 + appParams.variabilityGenerationInterval*rand(simValues.maxID,1);
    timeManagement.generationIntervalDeterministicPart(stationManagement.activeIDsCV2X) = appParams.generationInterval;
end
% this additional delay can be used to add a delay from application to
% access layer or to add an artificial delay in the generatioon
timeManagement.addedToGenerationTime = zeros(simValues.maxID,1);

% From v5.2.5: RSU DENM and hpDENM are sent at fixed 20 Hz
if appParams.nRSUs>0 && ~strcmpi(appParams.RSU_pckTypeString,'CAM')
    timeManagement.generationIntervalDeterministicPart(end-appParams.nRSUs+1:end) = 0.05;
end
%timeManagement.generationIntervalDeterministicPart(stationManagement.activeIDsCV2X) = appParams.averageTbeacon;
timeManagement.timeNextPacket = Inf * ones(simValues.maxID,1);
timeManagement.timeNextPacket(stationManagement.activeIDs) = timeManagement.generationIntervalDeterministicPart(stationManagement.activeIDs) .* rand(length(stationManagement.activeIDs),1);
timeManagement.timeLastPacket = -1 * ones(simValues.maxID,1); % needed for the calculation of the CBR

timeManagement.dcc_minInterval = zeros(simValues.maxID,1);
stationManagement.dcc11pTriggered = false(1,phyParams.nChannels);
stationManagement.dccLteTriggered = false(1,phyParams.nChannels);
stationManagement.dccLteTriggeredHarq = false(1,phyParams.nChannels);

% Initialization of variables related to transmission in LTE-V2V - must be
% initialized also if 11p is not present
%if simParams.technology~=2 % if not only 11p
    sinrManagement.coex_currentInterfFrom11pToLTE = zeros(simValues.maxID,1);
    sinrManagement.coex_currentInterfEach11pNodeToLTE = zeros(simValues.maxID,simValues.maxID);
%end
% Initialization of variables related to transmission in 11p - must be
% initialized also if LTE is not present
%if simParams.technology~=1 % if not only LTE
   sinrManagement.coex_InterfFromLTEto11p = zeros(simValues.maxID,1);
%end

%% Initialize propagation
% Tx power vectors
if isfield(phyParams,'P_ERP_MHz_CV2X')
    if phyParams.FixedPdensity
        % Power density is fixed, must be scaled based on subchannels
        phyParams.P_ERP_MHz_CV2X = phyParams.P_ERP_MHz_CV2X * (phyParams.NsubchannelsBeacon/phyParams.NsubchannelsFrequency);
    end %else % Power is fixed, independently to the used bandwidth
    phyParams.P_ERP_MHz_CV2X = phyParams.P_ERP_MHz_CV2X*ones(simValues.maxID,1);
else
    phyParams.P_ERP_MHz_CV2X = -ones(simValues.maxID,1);
end
if isfield(phyParams,'P_ERP_MHz_11p')
    phyParams.P_ERP_MHz_11p = phyParams.P_ERP_MHz_11p*ones(simValues.maxID,1);
else
    phyParams.P_ERP_MHz_11p = -ones(simValues.maxID,1);
end

% Vehicles in a technology have the power to -1000 in the other; this is helpful for
% verification purposes
phyParams.P_ERP_MHz_CV2X(stationManagement.vehicleState~=100) = -1000;
phyParams.P_ERP_MHz_11p(stationManagement.vehicleState==100) = -1000;

%% Channels
stationManagement.vehicleChannel = ones(simValues.maxID,1);
% NOTE: sinrManagement.mcoCoefficient( RECEIVER, TRANSMITTER) 
sinrManagement.mcoCoefficient = ones(simValues.maxID,simValues.maxID);
if phyParams.nChannels>1
    [stationManagement,sinrManagement,phyParams] = mco_channelInit(stationManagement,sinrManagement,simValues,phyParams);
end

% Shadowing matrix
sinrManagement.Shadowing_dB = randn(length(stationManagement.activeIDs),length(stationManagement.activeIDs))*phyParams.stdDevShadowLOS_dB;
sinrManagement.Shadowing_dB = triu(sinrManagement.Shadowing_dB,1)+triu(sinrManagement.Shadowing_dB)';

%% Management of coordinates and distances
% Init knowledge at eNodeB of nodes positions
%if simParams.technology~=2 % not only 11p
if sum(stationManagement.vehicleState(stationManagement.activeIDs)==100)>0    
    % Number of groups for position update
 	positionManagement.NgroupPosUpdate = round(simParams.Tupdate/appParams.allocationPeriod);
    % Assign update period to all vehicles (introduce a position update delay)
    positionManagement.posUpdateAllVehicles = randi(positionManagement.NgroupPosUpdate,simValues.maxID,1);
else
    positionManagement.NgroupPosUpdate = -1;
end

% Copy real coordinates into estimated coordinates at eNodeB (no positioning error)
simValues.XvehicleEstimated = positionManagement.XvehicleReal;
simValues.YvehicleEstimated = positionManagement.YvehicleReal;

% Call function to compute distances
% computeDistance(i,j): computeDistance from vehicle with index i to vehicle with index j
% positionManagement.distance matrix has dimensions equal to simValues.IDvehicle x simValues.IDvehicle in order to
% speed up the computation (only vehicles present at the considered instant)
% positionManagement.distance(i,j): positionManagement.distance from vehicle with index i to vehicle with index j
[positionManagement,stationManagement] = computeDistance (simParams,simValues,stationManagement,positionManagement);

% Save positionManagement.distance matrix
positionManagement.XvehicleRealOld = positionManagement.XvehicleReal;
positionManagement.YvehicleRealOld =  positionManagement.YvehicleReal;
positionManagement.distanceRealOld = positionManagement.distanceReal;
positionManagement.angleOld = zeros(length(positionManagement.XvehicleRealOld),1);

% Computation of the channel gain
% 'dUpdate': vector used for the calculation of correlated shadowing
dUpdate = zeros(outputValues.Nvehicles,outputValues.Nvehicles);
[sinrManagement,simValues.Xmap,simValues.Ymap,phyParams.LOS] = computeChannelGain(sinrManagement,stationManagement,positionManagement,phyParams,simParams,dUpdate);

% Update of the neighbors
[positionManagement,stationManagement] = computeNeighbors (stationManagement,positionManagement,phyParams);

% The variable 'timeManagement.timeNextPosUpdate' is used for updating the positions
timeManagement.timeNextPosUpdate = simParams.positionTimeResolution;
positionManagement.NposUpdates = 1;

% Number of neighbors
[outputValues,~,~,~] = updateAverageNeighbors(simParams,stationManagement,outputValues,phyParams);

% Init of matrixes counting vehicles in range
if outParams.printUpdateDelay && outParams.printWirelessBlindSpotProb
    outputValues.enteredInRangeLTE = -1 * ones(simValues.maxID,simValues.maxID,length(phyParams.Raw));
    for iRaw = 1:length(phyParams.Raw)
        valuesEnteredInRange = outputValues.enteredInRangeLTE(:,:,iRaw);
        valuesEnteredInRange(stationManagement.activeIDsCV2X,stationManagement.activeIDsCV2X) = (positionManagement.distanceReal(stationManagement.activeIDsCV2X,stationManagement.activeIDsCV2X)<=phyParams.Raw(iRaw))-1;
        outputValues.enteredInRangeLTE(:,:,iRaw) = valuesEnteredInRange - diag(diag(valuesEnteredInRange+1));        
    end
    outputValues.enteredInRange11p = -1 * ones(simValues.maxID,simValues.maxID,length(phyParams.Raw));
    for iRaw = 1:length(phyParams.Raw)
        valuesEnteredInRange = outputValues.enteredInRange11p(:,:,iRaw);
        valuesEnteredInRange(stationManagement.activeIDs11p,stationManagement.activeIDs11p) = (positionManagement.distanceReal(stationManagement.activeIDs11p,stationManagement.activeIDs11p)<=phyParams.Raw(iRaw))-1;
        outputValues.enteredInRange11p(:,:,iRaw) = valuesEnteredInRange - diag(diag(valuesEnteredInRange+1));        
    end
end

% Floor coordinates for PRRmap creation (if enabled)
if simParams.typeOfScenario==2 && outParams.printPRRmap % Only traffic traces
    simValues.XmapFloor = floor(simValues.Xmap);
    simValues.YmapFloor = floor(simValues.Ymap);
end

%% Initialization of variables related to transmission in IEEE 802.11p
% 'timeNextTxRx11p' stores the instant of the next backoff or
% transmission end, if the station is 11p - not used in LTE and therefore
% init to inf in all cases
timeManagement.timeNextTxRx11p = Inf * ones(simValues.maxID,1);
%
if sum(stationManagement.vehicleState(stationManagement.activeIDs)~=100)>0
%if simParams.technology~=1 % if not only LTE
    % When a node senses the medium as busy and goes to State RX, the
    % transmitting node is saved in 'idFromWhichRx'
    % Note that once a node starts receiving a signal, it will not be able to
    % synchronize to a different signal, thus there is no reason to change this
    % value before exiting from State RX
    % 'idFromWhichRx' is set to the id of the node if the node is not receiving
    % (a number must be set in order to avoid exceptions running the code that follow)
    sinrManagement.idFromWhichRx11p = (1:simValues.maxID)';

    % Possible events: A) New packet, B) Backoff ends, C) Transmission end;
    % A - 'timeNextPacket' stores the instant of the next message generation; the
    % first instant is randomly chosen within 0-Tbeacon
    %timeManagement.timeNextGeneration11p = timeManagement.timeNextPacket;
    timeManagement.cbr11p_timeStartBusy = -1 * ones(simValues.maxID,1); % needed for the calculation of the CBR
    timeManagement.cbr11p_timeStartMeasInterval = -1 * ones(simValues.maxID,1); % needed for the calculation of the CBR

    % Total power being received from nodes in State 3
    sinrManagement.rxPowerInterfLast11p = zeros(simValues.maxID,1);
    sinrManagement.rxPowerUsefulLast11p = zeros(simValues.maxID,1);
 
    % Instant when the power store in 'PrTot' was calculated; it will remain
    % constant until a new calculation will be performed
    %sinrManagement.instantThisPrStarted11p = Inf;
    sinrManagement.instantThisSINRstarted11p = ones(simValues.maxID,1)*Inf;

    % Average SINR - This parameter is irrelevant if the node is not in State 9
    sinrManagement.sinrAverage11p = zeros(simValues.maxID,1);
    sinrManagement.interfAverage11p = zeros(simValues.maxID,1);

    % Instant when the average SINR of a node in State 9 was initiated - This
    % parameter is irrelevant if the node is not in State 9
    sinrManagement.instantThisSINRavStarted11p = Inf * ones(simValues.maxID,1);

    % Number of slots for the backoff - Set to '-1' when not initiated
    stationManagement.nSlotBackoff11p = -1 * ones(simValues.maxID,1);
    % Init of AIFS and CW per station
    stationManagement.CW_11p = ones(simValues.maxID,1) * phyParams.CW;
    stationManagement.tAifs_11p = ones(simValues.maxID,1) * phyParams.tAifs;
    % Removal from struct to avoid mistakes
    %phyParams = rmfield( phyParams , 'CW' );
    %phyParams = rmfield( phyParams , 'AifsN' );
    phyParams = rmfield( phyParams , 'tAifs' );
    if appParams.nRSUs>0 && ~strcmpi(appParams.RSU_pckTypeString,'CAM')
        if strcmpi(appParams.RSU_pckTypeString,'hpDENM')
            % High priority DENM: CWmax=3, AIFS=58us
            stationManagement.CW_11p(end-appParams.nRSUs+1:end) = 3;
            stationManagement.tAifs_11p(end-appParams.nRSUs+1:end) = 58e-6;
        elseif strcmpi(appParams.RSU_pckTypeString,'DENM')
            % DENM: CWmax=7, AIFS=71us
            stationManagement.CW_11p(end-appParams.nRSUs+1:end) = 7;
            stationManagement.tAifs_11p(end-appParams.nRSUs+1:end) = 71e-6;
        else
            error('Something wrong with the packet type of RSUs');
        end
    end
    
    % Prepare matrix for update delay computation (if enabled)
    if outParams.printUpdateDelay
        % Reset update time of vehicles that are outside the scenario
        allIDOut = setdiff(1:simValues.maxID,stationManagement.activeIDs);
        simValues.updateTimeMatrix11p(allIDOut,:) = -1;
        simValues.updateTimeMatrix11p(:,allIDOut) = -1;
    end

    % Prepare matrix for data age computation (if enabled)
    if outParams.printDataAge
        % Reset update time of vehicles that are outside the scenario
        allIDOut = setdiff(1:simValues.maxID,stationManagement.activeIDs);
        simValues.dataAgeTimestampMatrix11p(allIDOut,:) = -1;
        simValues.dataAgeTimestampMatrix11p(:,allIDOut) = -1;
    end
    
    % Initialization of a matrix containing the duration the channel has
    % been sensed as busy, if used
    % Note: 11p CBR is calculated over a fixed number of beacon periods; 
    % this implies that if they are not all the same among vehciles, then 
    % the duration of the sensing interval is not the same
    %if outParams.printCBR || (simParams.technology==4 && simParams.coexMethod~=0 && simParams.coex_slotManagement==2 && simParams.coex_cbrTotVariant==2)
    %    stationManagement.channelSensedBusyMatrix11p = zeros(ceil(simParams.cbrSensingInterval/appParams.averageTbeacon),simValues.maxID);        
    %else
    %    % set to empty if not used
    %    stationManagement.channelSensedBusyMatrix11p = [];
    %end

    % Conversion of sensing power threshold when hidden node probability is active
    if outParams.printHiddenNodeProb
        %% TODO - needs update
        error('Not updated in v5');
        %if outParams.Pth_dBm==1000
        %    outParams.Pth_dBm = 10*log10(phyParams.gammaMin*phyParams.PnBW*(appParams.RBsBeacon/2))+30;
        %end
        %outParams.Pth = 10^((outParams.Pth_dBm-30)/10);
    end

    % Initialize vector containing variable beacon periodicity
    if simParams.technology==2 && appParams.variableBeaconSize
        % Generate a random integer for each vehicle indicating the period of
        % transmission (1 corresponds to the transmission of a big beacon)
        stationManagement.variableBeaconSizePeriodicity = randi(appParams.NbeaconsSmall+1,simValues.maxID,1);
    else
        stationManagement.variableBeaconSizePeriodicity = 0;
    end

end % end of not only LTE

%% Coexistence
% Settings of Coexistence must be before BR assignment initialization
timeManagement.coex_timeNextSuperframe = inf * ones(simValues.maxID,1);
sinrManagement.coex_virtualInterference = zeros(simValues.maxID,1);
sinrManagement.coex_averageSFinterfFrom11pToLTE = zeros(simValues.maxID,1);
if simParams.technology==4 && simParams.coexMethod~=0
    [timeManagement,stationManagement,sinrManagement,simParams,phyParams] = mainInitCoexistence(timeManagement,stationManagement,sinrManagement,simParams,simValues,phyParams,appParams);
end
if simParams.technology==4 
    % Initialization of the matrix coex_correctSCIhistory
    sinrManagement.coex_correctSCIhistory = zeros(appParams.NbeaconsT*appParams.NbeaconsF,simValues.maxID);
end

% vector sensedPowerByLteNo11p created (might remain void)
sinrManagement.sensedPowerByLteNo11p = [];


%% Initialization of variables related to transmission in IEEE 802.11p
% Initialize the beacon resource used by each vehicle
stationManagement.BRid = -2*ones(simValues.maxID,phyParams.cv2xNumberOfReplicasMax);
stationManagement.BRid(stationManagement.activeIDs,:) = -1;
%
% Initialize next LTE event to inf
timeManagement.timeNextCV2X = inf;
%
if sum(stationManagement.vehicleState(stationManagement.activeIDs)==100)>0
%if simParams.technology ~= 2 % not only 11p

    % Initialization of resouce allocation algorithms in LTE-V2X
   if simParams.BRAlgorithm==2 || simParams.BRAlgorithm==7 || simParams.BRAlgorithm==10
        % Number of groups for scheduled resource reassignment (BRAlgorithm=2, 7 or 10)
        stationManagement.NScheduledReassignLTE = round(simParams.Treassign/appParams.allocationPeriod);

        % Assign update period to vehicles (BRAlgorithm=2, 7 or 10)
        stationManagement.scheduledReassignLTE = randi(stationManagement.NScheduledReassignLTE,simValues.maxID,1);
    end

    if simParams.BRAlgorithm==18
        % Find min and max values for random counter (BRAlgorithm=18)
        [simParams.minRandValueMode4,simParams.maxRandValueMode4] = findRCintervalAutonomous(appParams.allocationPeriod,simParams);

        % timeManagement.timeOfResourceAllocationLTE is for possible use in the future
        % Inizialization of instant when the reselection is evaluated
        %timeManagement.timeOfResourceAllocationLTE = -1*ones(simValues.maxID,1);
        %timeManagement.timeOfResourceAllocationLTE(stationManagement.activeIDsCV2X) = timeManagement.timeNextPacket(stationManagement.activeIDsCV2X);

        % Initialize reselection counter (BRAlgorithm=18)
        stationManagement.resReselectionCounterCV2X = Inf*ones(simValues.maxID,1);
        stationManagement.resReselectionCounterCV2X(stationManagement.activeIDs) = (simParams.minRandValueMode4-1) + randi((simParams.maxRandValueMode4-simParams.minRandValueMode4)+1,1,length(stationManagement.activeIDs));
        % COMMENTED: Set value 0 to vehicles that are blocked
        % stationManagement.resReselectionCounterCV2X(stationManagement.BRid==-1)=0;

        % Initialization of sensing matrix (BRAlgorithm=18)
        stationManagement.sensingMatrixCV2X = zeros(ceil(simParams.TsensingPeriod/appParams.allocationPeriod),appParams.Nbeacons,simValues.maxID);
        stationManagement.knownUsedMatrixCV2X = zeros(appParams.Nbeacons,simValues.maxID);

        % First random allocation 
        %[stationManagement.BRid,~] = BRreassignmentRandom(simValues.IDvehicle,stationManagement.BRid,simParams,sinrManagement,appParams);
        %[stationManagement.BRid(stationManagement.activeIDs,1),~] = BRreassignmentRandom(stationManagement.activeIDs,simParams,timeManagement,sinrManagement,stationManagement,phyParams,appParams);
        for j=1:phyParams.cv2xNumberOfReplicasMax
            % From v5.4.16, when HARQ is active, n random
            % resources are selected, one per each replica 
            [stationManagement.BRid(stationManagement.activeIDs,j),~] = BRreassignmentRandom(simParams.T1autonomousModeTTIs,simParams.T2autonomousModeTTIs,stationManagement.activeIDs,simParams,timeManagement,sinrManagement,stationManagement,phyParams,appParams);
        end      
        % Must be ordered with respect to the packet generation instant
        % (Vittorio 5.5.3)
        % subframeGen = ceil(timeManagement.timeNextPacket/phyParams.Tsf);
        subframeGen = ceil(timeManagement.timeNextPacket/phyParams.TTI);
        subframe_BR = ceil(stationManagement.BRid/appParams.NbeaconsF);
        stationManagement.BRid = stationManagement.BRid + (subframe_BR<=subframeGen) * appParams.Nbeacons;
        stationManagement.BRid = sort(stationManagement.BRid,2);
        stationManagement.BRid = stationManagement.BRid - (stationManagement.BRid>appParams.Nbeacons) * appParams.Nbeacons;
        
        % vector correctSCImatrixCV2X created
        stationManagement.correctSCImatrixCV2X = [];
    end

    %if simParams.BRAlgorithm==101
        % The random allocation is performed when the packet is generated
        % Therefore nothing needs to be done here
    %end
    
    % Initialization of lambda: SINR threshold for BRAlgorithm 9
    if simParams.BRAlgorithm==9
        stationManagement.lambdaLTE = phyParams.sinrThresholdCV2X_LOS;
    end

    % Conversion of sensing power threshold when hidden node probability is active
    if outParams.printHiddenNodeProb
        %% TODO - needs update
        error('Not updated in v5');
        %if outParams.Pth_dBm==1000
        %    outParams.Pth_dBm = 10*log10(phyParams.gammaMin*phyParams.PnRB*(appParams.RBsBeacon/2))+30;
        %end
        %outParams.Pth = 10^((outParams.Pth_dBm-30)/10);
        %outParams.PthRB = outParams.Pth/(appParams.RBsBeacon/2);
    end
    
    % The next instant in C-V2X will be the beginning
    % of the first TTI in 0
    timeManagement.timeNextCV2X = 0;
    timeManagement.ttiCV2Xstarts = true;
    
    % The channel busy ratio of C-V2X is initialized
    sinrManagement.cbrCV2X = zeros(simValues.maxID,1);
    sinrManagement.cbrLTE_coexLTEonly = zeros(simValues.maxID,1);
end % end of if simParams.technology ~= 2 % not only 11p

% if CBR is active, set the next CBR instant - else set to inf
if simParams.cbrActive
    
    if simParams.technology==4 && simParams.coexMethod==1
        if mod(simParams.coex_superFlength/simParams.cbrSensingInterval, 1) ~= 0 && ...
           mod(simParams.cbrSensingInterval/simParams.coex_superFlength, 1) ~= 0
            error('coex, Method A, cbrSensingInterval must be a multiple or a divisor of coex_superFlength');
        end
    end   
    
    timeManagement.timeNextCBRupdate = simParams.cbrSensingInterval/simParams.cbrSensingIntervalDesynchN;
    stationManagement.cbr_subinterval = randi(simParams.cbrSensingIntervalDesynchN,simValues.maxID,1);
    
    timeManagement.cbr11p_timeStartMeasInterval(stationManagement.activeIDs11p) = 0;
    timeManagement.cbr11p_timeStartBusy = -1 * ones(simValues.maxID,1);
    if simParams.technology==4 && simParams.coexMethod==1
        timeManagement.cbr11p_timeStartBusy(stationManagement.activeIDs .* timeManagement.coex_superframeThisIsLTEPart(stationManagement.activeIDs)) = 0;
    end    
    if simParams.technology~=1 % Not only C-V2X
        stationManagement.channelSensedBusyMatrix11p = zeros(ceil(simParams.cbrSensingInterval/appParams.allocationPeriod),simValues.maxID);        
    end
    
    nCbrIntervals = ceil(simParams.simulationTime/simParams.cbrSensingInterval);
    stationManagement.cbr11pValues = -1 * ones(simValues.maxID,nCbrIntervals); 
    stationManagement.cbrCV2Xvalues = -1 * ones(simValues.maxID,nCbrIntervals);     
    stationManagement.coex_cbrLteOnlyValues = -1 * ones(simValues.maxID,nCbrIntervals);     
else
    timeManagement.timeNextCBRupdate = inf;
end

% BRid set to -1 for non-LTE
stationManagement.BRid(stationManagement.vehicleState~=100,:)=-3;

% Temporary
% %% INIT FOR MCO
% if simParams.mco_nVehInterf>0
%     sinrManagement.mco_shadowingInterferers_dB = [];
%     % mco_perceivedInterference is a matrix with one line per position update step
%     % and one column per interferer
%     outputValues.mco_perceivedInterferenceIndex = 1;
%     outputValues.mco_perceivedInterference = -1*ones(10000,simParams.mco_nVehInterf+1);
%     [sinrManagement,positionManagement,outputValues] = mco_interfVehiclesCalculate(timeManagement,stationManagement,sinrManagement,positionManagement,phyParams,appParams,outputValues,simParams);
% end

%% Initialization of time variables
% Stores the instant of the next event among all possible events;
% initially set to the first packet generation
timeManagement.timeNextEvent = Inf * ones(simValues.maxID,1);
timeManagement.timeNextEvent(stationManagement.activeIDs) = timeManagement.timeNextPacket(stationManagement.activeIDs);

if simParams.NumColli
    stationManagement.NumColli = 0;
    stationManagement.NumAllConnect = 0;  %%%  两两连接的个数
end