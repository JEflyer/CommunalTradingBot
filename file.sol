pragma solidity 0.8.15;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract Trader is ReentrancyGuard {

    address private admin;
    
    address private bot;

    address private USDC;

    address private WMatic;

    IUniswapV2Router02 private router;

    struct StakeData {
        uint256 amountStaked;
        uint256 stepStaked;
    }

    struct Order {
        uint256 purchasePrice;
        uint256 maticAmount;
        uint256 usdAmount;
    }

    mapping(address => StakeData[]) private stakingData;

    mapping(uint256 => Order) private orders;

    uint256[] private activeOrderIDs;
    uint256[] private closedOrderIDs;

    uint256 currentOrderID;

    uint256 lastActionPrice;
    uint256 lastPrice;

    struct Step {
        uint256 totalUSDDeposited;
        uint256 profit;
        uint256 currentUSDBal;
        uint256 currentETHBal;
        uint256 blockNum;
        bool madeSale;
    }

    mapping(uint256 => Step) private stepDetails;

    uint256 currentStepID;

    constructor(
        address _bot,
        address _USDC,
        address _WMatic,
        address _router
    ){
        bot = _bot;
        USDC = _USDC;
        admin = msg.sender;
        WMatic = _WMatic;
        router = IUniswapV2Router02(_router);
        currentOrderID = 0;
        lastActionPrice = 0;
        lastPrice = 0;
        currentStepID = 0;
    }

    modifier onlyAdmin {
        require(_msgSender() == admin, "ERR:NA");//NA => Not Admin
        _;
    }

    modifier notNull(address addr){
        require(addr != address(0),"ERR:ZA");//ZA => Zero Address
        _;
    }

    function setAdmin(address _new) external notNull(_new) onlyAdmin {
        admin = _new;
    }

    function relinquishControl() external onlyAdmin {
        delete admin;
    }

    function setBot(address _new) external notNull(_new) onlyAdmin {
        bot = _new;
    }

    function updateRouter(address _new) external notNull(_new) onlyAdmin {
        router = IUniswapV2Router02(_new);
    }

    function stakeFunds(uint256 amount) external {

        //Check that the amount being staked is greater than zero
        require(amount != 0,"ERR:NA");//NA => Null Amount

        //Retrieve the address of the caller
        address caller = _msgSender();

        //Build an instance of the ERC20 interface for USDC
        IERC20 token = IERC20(USDC);

        //Retrieve the amount the caller has approved this contract to spend
        uint256 amountApproved = token.allowance(caller,address(this));

        //Check that the amount approved is greater than or equal to the amount the caller is trying to stake
        require(amountApproved >= amount,"ERR:NE");//NE => Not Enough

        //Pull the StakeData for this caller
        StakeData storage data = stakingData[caller];

        //Check that the user has not already staked
        require(data.stepStaked == 0, "ERR:AS");

        //Transfer the USD from the caller to this contract
        token.transferFrom(caller,address(this),amount);

        //Save info on step
        Step storage step = stepDetails[++currentStepID];
        step.currentETHBal = address(this).balance;
        step.currentUSDBal = token.balanceOf(address(this));
        step.blockNum = block.number;
        step.totalUSDDeposited += amount;

        //Save the callers stake data
        data.amountStaked = amount;
        data.stepStaked = currentStepID;


        //Emit event
    }

    function withdrawFunds() external {

        address caller = msg.sender;

        StakeData storage data = stakingData[caller];

        require(data.stepStaked != 0, "ERR:AS");
        
        //Calculate the total reward
        uint256 payout = data.amountStaked + calculateDueReward();

        //Payout user
        IERC20(USDC).transfer(caller, payout);

        //Save info on step
        Step storage step = stepDetails[++currentStepID];
        step.currentETHBal = address(this).balance;
        step.currentUSDBal = token.balanceOf(address(this));
        step.blockNum = block.number;
        step.totalUSDDeposited -= data.amountStaked;

        //Delete stake info
        delete data;

        //Emit event

    }

    function calculateDueReward(address query) public view returns(uint256 reward) {
        //Find the stakeData the user staked on
        StakeData memory data = stakingData[caller];

        //Iterate through all the steps since
        for(uint256 i = data.stepStaked; i <= currentStepID; ){

            Step memory step = stepDetails[i];
            
            if(step.madeSale){
                reward += (data.amountStaked * step.profit) / step.totalUSDDeposited;
            }

            unchecked{
                i++;
            }
        }
    }

    function update() external {

        //Check that the caller is the authorised bot
        require(msg.sender == bot, "ERR:NA");//NA => Not Authorised

        //Make a path from Matic to USDC
        address[] memory path;
        path[0] = WMatic;
        path[1] = USDC;

        //Get the current price for 1 Matic
        uint256 currentPrice = router.getAmountsOut(
            1 * 10 ** 18,
            path
        );

        IERC20 token = IERC20(USDC);


        //If this is the first time the update function is being called
        if(lastPrice == 0){

            //Set the lastActionPrice & lastPrice to the currentPrice
            lastActionPrice = currentPrice;
            lastPrice = currentPrice; 
        }else {

            //Calculate the maximum price that we will check against 2.5% higher than the last action price
            uint256 maxClimb = (lastActionPrice /40) + lastActionPrice; 


            //If the currentPrice is greater than the last price and lower than the maxClimb 
            if(currentPrice > lastPrice && currentPrice < maxClimb){
                //Set the last price in storage
                lastPrice = currentPrice;
            }

            //Make a path from USDC to Matic
            address[] memory purchase_path;
            path[0] = USDC;
            path[1] = WMatic;

            //If we have hit purchase price
            if(currentPrice <= lastPrice - (lastPrice / 20)){

                //Retrieve the current USD balance
                uint256 balance = token.balanceOf(address(this));

                //Calculate the amount to convert to matic - 5% of USD balance
                uint256 purchaseAmount = balance / 20;

                require(purchaseAmount > 0, "ERR:PA");//PA => Purchase amount

                //Approve
                token.approve(address(router),purchaseAmount);

                uint256 ETHBalBefore = address(this).balance;

                //Purchase
                router.swapExactTokensForETH(
                    purchaseAmount,
                    0,
                    purchase_path,
                    address(this),
                    block.timestamp + 1
                );

                uint256 ETHGained = address(this).balance - ETHBalBefore;

                require(ETHGained > 0, "ERR:NG");//NG => Nothing Gained

                //Emit event


                //Store last action price
                lastActionPrice = currentPrice;

                //Open the new order
                uint256 orderId = ++currentOrderID;

                orders[orderId].purchasePrice = currentPrice;
                orders[orderId].maticAmount = ETHGained;
                orders[orderId].usdAmount = purchaseAmount;

                activeOrderIDs.push(orderId);

                // Save step
                Step storage step = stepDetails[++currentStepID];
                step.currentETHBal = address(this).balance;
                step.currentUSDBal = token.balanceOf(address(this));
                step.blockNum = block.number;
                
                if(step.totalUSDDeposited == 0){
                    step.totalUSDDeposited = stepDetails[currentStepID - 1].totalUSDDeposited;
                }
                
            }
            
            //Pull the active ordersIDs into memory
            uint256[] memory orderIDs = activeOrderIDs; 

            //Define a variable that will be used multiple times
            uint256 sellPrice;

            //Iterate through the orders
            for(uint i = 0; i < orderIDs.length;){

                //Calculate the sale price
                sellPrice = orders[orderIDs[i]].purchasePrice + (orders[orderIDs[i]].purchasePrice / 20);

                //If the sell point has been made for this order then sell the Matic
                if(currentPrice >= sellPrice){
                    //Retrieve the USD balance 
                    uint256 USDBalBefore = token.balanceOf(address(this));

                    //Sell 
                    router.swapExactETHForTokens{value: orders[orderIDs[i]].maticAmount}(
                        0,
                        path,
                        address(this),
                        block.timestamp + 1
                    );

                    //Calculate the total amount that the trade gained
                    uint256 USDGained = token.balanceOf(address(this)); 

                    //Check that the trade was successful
                    require(USDGained > 0, "ERR:SA");//SA => Sell Amount

                    //Emit event


                    //Store last action price
                    lastActionPrice = currentPrice;

                    // Get step
                    if(stepDetails[currentStepID].blockNum == block.number){
                        Step storage step = stepDetails[currentStepID];
                    }else {
                        Step storage step = stepDetails[++currentStepID];
                    }

                    //Save step
                    step.profit += USDGained -orders[orderIDs[i]].usdAmount;
                    step.currentUSDBal = token.balanceOf(address(this));
                    step.currentETHBal = address(this).balance;
                    step.madeSale = true;
                    
                    if(step.totalUSDDeposited == 0){
                        step.totalUSDDeposited = stepDetails[currentStepID - 1].totalUSDDeposited;
                    }

                    //Close this order ID
                    closedOrderIDs.push(activeOrderIDs[i]);
                    delete activeOrderIDs[i];
                    activeOrderIDs[i] = activeOrderIDs[activeOrderIDs.length - 1];
                    activeOrderIDs.pop();
                }
                
                unchecked {
                    i++;
                }
            }
        }
    }
}
