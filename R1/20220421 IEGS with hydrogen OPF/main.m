clear
clc
yalmip('clear')

%% parameters
[mpc,gtd] = case24GEv6(); 
mpc.gen(:,10) = 0; % 最小出力为0
% mpc.branch(:,6:8) = mpc.branch(:,6:8); % 线路容量/3
mpc.branch([30,32,33],6) = mpc.branch([30,32,33],6)/2.5;
%
[PQ, PV, REF, NONE, BUS_I, BUS_TYPE, PD, QD, GS, BS, BUS_AREA, VM, ...
    VA, BASE_KV, ZONE, VMAX, VMIN, LAM_P, LAM_Q, MU_VMAX, MU_VMIN] = idx_bus;
[GEN_BUS, PG, QG, QMAX, QMIN, VG, MBASE, GEN_STATUS, PMAX, PMIN, ...
    MU_PMAX, MU_PMIN, MU_QMAX, MU_QMIN, PC1, PC2, QC1MIN, QC1MAX, ...
    QC2MIN, QC2MAX, RAMP_AGC, RAMP_10, RAMP_30, RAMP_Q, APF] = idx_gen;
[F_BUS, T_BUS, BR_R, BR_X, BR_B, RATE_A, RATE_B, RATE_C, ...
    TAP, SHIFT, BR_STATUS, PF, QF, PT, QT, MU_SF, MU_ST, ...
    ANGMIN, ANGMAX, MU_ANGMIN, MU_ANGMAX] = idx_brch;
[PW_LINEAR, POLYNOMIAL, MODEL, STARTUP, SHUTDOWN, NCOST, COST] = idx_cost;
baseMVA = 100;
il = find(mpc.branch(:, RATE_A) ~= 0 & mpc.branch(:, RATE_A) < 1e10);
%
nb   = size(mpc.bus, 1);    %% number of buses
nGb  = size(mpc.Gbus,1); % number of gas bus
nGl = size(mpc.Gline,1);
nGen = sum(mpc.gen(:,22)==1)+sum(mpc.gen(:,22)==0);% all gen(TFU and GFU), excluded dispatchable loads
nGs = size(mpc.Gsou,1);
nLCg = size(find(mpc.Gbus(:,3)~=0),1);
nPTG = size(mpc.ptg,1);

[GCV_hy, GCV_gas, M_hy, M_gas, M_air, R_air, T_stp, Prs_stp, Z, T_gas,etaPTG,etaGFU] = initializeParameters();

%%
GEresult0 = GErunopf(mpc);
% 
Prsmin = mpc.Gbus(:,5); Prsmax = mpc.Gbus(:,6); % bar
PGsmin = mpc.Gsou(:,3); PGsmax = mpc.Gsou(:,4); % Mm3/day
Qptgmin = mpc.ptg(:,5); Qptgmax = mpc.ptg(:,6);
Pgmin = mpc.gen(:, PMIN) / baseMVA *0; %Pgmin is set to zero
Pgmax = mpc.gen(:, PMAX) / baseMVA;
LCgmin = zeros(nLCg,1);
LCgmax = mpc.Gbus(mpc.Gbus(:,3)~=0,3).*0;  
refs = find(mpc.bus(:, BUS_TYPE) == REF);
Vau = Inf(nb, 1);       %% voltage angle limits
Val = -Vau;
Vau(refs) = 1;   %% voltage angle reference constraints
Val(refs) = 1;
gasFlowMax = mpc.Gline(:,5);
WobbeIndexMin = 0.95;
WobbeIndexMax = 1.05; % 采用百分比，一般波动在5%-10%之间
GCVmin = 0.95;
GCVmax = 1.05;
% initial value
Prs_square0 = GEresult0.Gbus(:,7).^2;
PGs0 = GEresult0.Gsou(:,5);
Qptg0 = 0;
Pg0 = GEresult0.gen(:,2)/baseMVA;
Va0 = GEresult0.bus(:,9)/180*pi;
LCg0 = 0;
composition_hy0 = 0;
composition_gas0 = 1;
for m = 1:nGl
    auxiliaryVar0(m,1) = sqrt(abs(Prs_square0(mpc.Gline(m,1))-Prs_square0(mpc.Gline(m,2))));
end
S_sqrt0 = sqrt(M_gas/M_air);
%% state variables
Prs_square = sdpvar(nGb,1); % bar^2
PGs = sdpvar(nGs,1); % Mm3/day
Qptg = sdpvar(nPTG,1);
Pg = sdpvar(size(mpc.gen,1),1); 
Va = sdpvar(nb,1);
LCg = sdpvar(nLCg,1);
composition_hy = sdpvar(nGb,1); % hydrogen, gas
composition_gas = sdpvar(nGb,1); 
auxiliaryVar = sdpvar(nGl,1); % 用于化去gasflow中的根号
S_sqrt = sdpvar(nGb,1);
%
assign(Prs_square,Prs_square0); assign(PGs,PGs0);
assign(Qptg,Qptg0); assign(Pg,Pg0);
assign(Va,Va0); assign(LCg,LCg0);
assign(composition_hy,composition_hy0); assign(composition_gas,composition_gas0);
assign(auxiliaryVar,auxiliaryVar0); 
assign(S_sqrt,S_sqrt0);
%% objective
objfcn = obj_operatingCost(Pg,PGs,LCg,mpc) - 0.1/6*1e6*sum(Qptg);

%% constraints
signGf = sign(GEresult0.Gline(:,6));
% calculate the gas flow of each pipeline
gasFlow = calculateGasFlowInEachPipeline(auxiliaryVar, S_sqrt, composition_hy, composition_gas,signGf, mpc,gtd,nGl,M_hy,M_gas,M_air,R_air,T_stp,Prs_stp,T_gas,Z); % m3/s
% calculate the GCV at each bus
for i = 1:nGb
    GCV(i) = GCV_hy*composition_hy(i) + GCV_gas*composition_gas(i);
end

% 1) box constraints
PrsBoxCons = [Prsmin.^2 <= Prs_square <= Prsmax.^2];
PGsBoxCons = [PGsmin <= PGs <= PGsmax];
QptgCons = [Qptgmin <= Qptg <= Qptgmax];
PgBoxCons = [Pgmin <= Pg <= Pgmax];
LCgBoxCons = [LCgmin <= LCg <= LCgmax];
VaBoxCons = [Val <= Va <= Vau];

% 2) 
electricPowerBalanceConsDC = [consfcn_electricPowerBalance(Va, Pg,Qptg,mpc,GCV_hy,etaPTG) == 0]:'electricPowerBalanceConsDC';
electricBranchFlowConsDC = [consfcn_electricBranchFlow(Va, mpc, il) <= 0]:'electricBranchFlowConsDC';
gasBalanceCons = [consfcn_gasBalance(PGs,Pg,composition_hy,composition_gas,Qptg, gasFlow, signGf, mpc, GCV_hy, GCV_gas,etaGFU,baseMVA)==0]:'gasBalanceCons';
gasFlowCons = [0 <= gasFlow'/1e6*24*3600 <= gasFlowMax]:'gasFlowCons';

% 3) 
compositionCons = [consfcn_composition(PGs,Qptg, gasFlow, composition_hy,composition_gas, mpc, signGf, nGb,nGl)]:'balanceOfComposition';
WobbeIndexCons = [WobbeIndexMin <= consfcn_WobbeIndex(composition_hy,composition_gas,S_sqrt, GCV, nGb,GCV_gas,M_hy,M_gas,M_air) <= WobbeIndexMax]:'WobbeIndexCons';
GCVcons = [GCVmin <= GCV/GCV_gas <= GCVmax]:'GCVcons';
% 4)
auxiliaryCons = [auxiliaryVar >=0 ];
for m = 1:nGl
    if signGf(m) == 1 % positive
        fb = mpc.Gline(m,1); tb = mpc.Gline(m,2);
    else
        fb = mpc.Gline(m,2); tb = mpc.Gline(m,1);
    end
    auxiliaryCons = [
        auxiliaryCons;
        Prs_square(fb)-Prs_square(tb) == auxiliaryVar(m)^2;
        ];
end
S_sqrtCons = [];
S_sqrt_gas = sqrt(M_gas/M_air);
for i = 1:nGb
    S_sqrtCons = [
        S_sqrtCons;
%         S_sqrt(i)^2 == ((M_hy*composition_hy(i) + M_gas*composition_gas(i)) / M_air) ;
        (2*S_sqrt(i)/S_sqrt_gas - 1) * S_sqrt_gas^2 == ((M_hy*composition_hy(i) + M_gas*composition_gas(i)) / M_air);
        ];
end

constraints = [
    PrsBoxCons;
    PGsBoxCons;
    QptgCons;
    PgBoxCons;
    LCgBoxCons;
    VaBoxCons;
    electricPowerBalanceConsDC;
    electricBranchFlowConsDC;
    gasBalanceCons;
    gasFlowCons;
    compositionCons;
    auxiliaryCons;
    S_sqrtCons;
    WobbeIndexCons;
    GCVcons;
    composition_hy+composition_gas == 1;
    0 <= composition_hy <= 0.1;
    0 <= composition_gas <= 1;
    ];
options = sdpsettings('verbose',2,'solver','ipopt', 'debug',1,'usex0',0);
% 
solution = optimize(constraints, objfcn, options);

%% results
Prs_square = value(Prs_square);
Prs = sqrt(value(Prs_square));
PGs = value(PGs); % Mm3/day
Qptg = value(Qptg);
Pg = value(Pg); 
Va = value(Va);
LCg = value(LCg);
composition_hy = value(composition_hy); % hydrogen, gas
composition_gas = value(composition_gas); 
auxiliaryVar = value(auxiliaryVar); % 用于化去gasflow中的根号
gasFlow = signGf .* value(gasFlow') / 1e6*24*3600;
S_sqrt = value(S_sqrt);
S = value(S_sqrt).^2;
GCV = value(GCV);
[~,WI] = consfcn_WobbeIndex(composition_hy,composition_gas,S_sqrt, GCV, nGb,GCV_gas,M_hy,M_gas,M_air);
WI = value(WI);
WIrelative = value(consfcn_WobbeIndex(composition_hy,composition_gas,S_sqrt, GCV, nGb,GCV_gas,M_hy,M_gas,M_air));