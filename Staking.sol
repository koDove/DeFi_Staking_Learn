// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract StakingRewards is Ownable{
    IERC20 public stakingToken;
    IERC20 public rewardsToken;

    //=====개념 정리=====
    //PoS 관점의 Staking과 DeFi 관점에서의 Staking 관점이 있다.
    //PoS 관점에서는 검증인에게 자금을 예치시킨 후 검증인이 이 자금을 통해서 블록 검증 후 수수료를 배분하는 방법이다.
    //DeFi 관점에서는 자금을 예치함으로써 잠금(Lock) 효과를 가져온다. 예금이 잠기면 유통되는 코인 매물이 줄어들고 가격이 상승하는 효과를 기대할 수 있다. 
    //Reward란 연이율 개념과 같다.
    //Staking의 업데이트 시간은 사용자가 스테이킹, 언스테이킹, 보상 인출하거나 관리자가 스테이킹 보상을 설정할 때 최신화된다.


    //=======사용되는 함수 리스트=======
    // totalSupply()
    // balanceOf(address account)
    // stake(uint256 amount) updateReward(msg.sender)
    // withdraw(uint256 amount) updateReward(msg.sender)
    // getReward() updateReward(msg.sender)
    // notifyRewardAmount(uint256 reward) onlyOwner updateReward(address(0))

    // lastTimeRewardApplicable(): 스테이킹 기간이 끝났는지 여부를 반환한다. 끝났으면 periodFinish, 아니면 현재 시간을 반환한다.
    // rewardPerToken(): 전체 구간을 구하는 함수이다.
    // earned(address account)

    //=======사용되는 modifier=======
    // updateReward(address account): 이 modifier는 조건 검증 뿐만 아니라 보상State를 업데이트하는 기능도 한다.
    // 자세히는 호출하는 account의 보상을 업데이트하는 로직을 실행한다.
    // 또한 스테이킹 amount가 바뀌는 시점에 모두 호출됨. 얘가 젤 중요함.

    //stake, withdraw, getReward 시에는  stake, withdraw, getReward -> updateReward() -> earned() -> rewardPerToken() -> lastTimeRewardApplicable() 까지 호출된다. 이후 역순으로 반환하며 각자의 함수 기능에 맞게 처리된다.
    //notifyRewardAmount 시에는 notifyRewardAmount -> updateReward() -> rewardPerToken() -> lastTimeRewardApplicable()

    //초당 제공할 리워드의 개수 이 계수를 통해서 Reward(연이율)가 계산된다.
    uint256 public rewardRate = 0;

    // 스테이킹 기간
    uint256 public rewardsDuration = 365 days;

    // 스테이킹이 끝나는 시간
    uint256 public periodFinish = 0;

    //마지막 업데이트 시간
    uint256 public lastUpdateTime;

    // 각 구간별 토큰당 리워드의 누적값(전체 구간의 리워드)
    uint256 public rewardPerTokenStored;

    //이미 계산된 유저의 리워드 총합
    mapping(address => uint256) public userRewardPerTokenPaid;

    // 출금 가능한 누적된 리워드의 총합(누적 보상)
    mapping(address => uint256) public rewards;

    //전체 스테이킹된 토큰 개수
    uint256 private _totalSupply;

    mapping(address => uint256) private _balances;

    constructor(address _rewardsToken, address _stakingToken){
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
    }//스테이킹 토큰, 보상 토큰으로 어떤 토큰을 사용할 것인지 명시하는 부분.

    function totalSupply() external view returns(uint256){
        return _totalSupply;
    }//스테이킹 토큰의 총 발행량을 출력한다.

    function balanceOf(address account) external view returns(uint256){
        return _balances[account];
    }//특정 유저가 스테이킹 풀에 예치한 토큰의 금액을 출력한다.

    function stake(uint256 amount) external updateReward(msg.sender){
        require(amount > 0 , "Cannot Stake 0");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.transferFrom(msg.sender, address(this), amount);
    }//stake 기능, approve 필요, 스테이킹으로 쓸 토큰을 유저에게 받아서 스테이큰 풀에 예치(발행량 증가, 유저 stake 잔액 증가)

    function withdraw(uint256 amount) public updateReward(msg.sender){
        require(amount >0 , "Cannot withdraw 0");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.transfer(msg.sender, amount);
    }//Unstake(발행량 감소, 유저 stake 잔액 감소)

    function getReward() public updateReward(msg.sender){
        uint256 reward = rewards[msg.sender];
        if(reward>0){
            rewards[msg.sender] = 0;
            rewardsToken.transfer(msg.sender, reward);
        }
    }//사용자가 보상을 수령하는 함수. 설정한 보상 토큰으로 준다. LP토큰과 비슷한 개념

    function notifyRewardAmount(uint256 reward) external onlyOwner updateReward(address(0)){
        if(block.timestamp >= periodFinish){
            //최초 보상을 설정하거나 스테이킹 기간이 아예 끝난 경우
            //periodFinish의 초기값은 0
            //매개변수로 들어온 reward가 3153600 (60*60*24*365)라면 1초당 1개의 리워드 코인이 분배된다.
            //이 말은 스테이킹 예치 시 1초당 1리워드 코인을 준다! 라는 말과 같다.
            rewardRate = reward / rewardsDuration;
        }else{
            //스테이킹 종료 전 추가로 리워드를 배정하는 경우
            uint256 remaning = periodFinish - block.timestamp;
            uint256 leftover = remaning * rewardRate;
            rewardRate = reward + leftover / rewardsDuration;
        }

        //스테이킹 풀에 잔액이 얼마나 남았는지 확인
        uint256 balance = rewardsToken.balanceOf(address(this));

        //제공할 보상은 스테이킹 풀의 잔액보다 크면 안됨.
        //예를 들어 reward로 1년을 설정할 경우 1년 뒤까지 지급할 충분한 잔액이 있을때 notifyRewardAmount가 설정된다.
        require(rewardRate <= balance / rewardsDuration, "Provided reward too high");

        //staking 관리자가 마지막으로 staking에 대해 설정한 시간을 저장한다.
        lastUpdateTime = block.timestamp;
    
        //스테이킹 종료 시간 업데이트, 현재 시간에서 1년을 연장한다. 
        periodFinish = block.timestamp + rewardsDuration;

    }//관리자가 staking 보상을 설정하는 함수이다. 이 보상 정도는 rewardRate 상태에 저장된다.

    function lastTimeRewardApplicable() public view returns(uint256){
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }//주기가 끝나지 않았으면 현재 블록 타입스탬프 반환

//=======중간 개념 정리=======
//rewardPerToken(): 구간에서 스테이킹 토큰 하나당 보상 토큰의 개수이다. 
//rewardPerTokenStored: 구간 변화에 따른 rewardPerToken의 누적값


    function rewardPerToken() public view returns(uint256){

        //발행량이 0이라면 스테이킹이 처음이라 누적값이 없기 때문에 0을 반환함.
        if(_totalSupply == 0){
            return rewardPerTokenStored;
        }
        //총 스테이킹량(_totalSupply)이 100개이고 구간 보상(rR*(lTRA-lUT)*1e18)이 5개인 경우에 스테이킹 토큰당 보상 리워드는 5/100개이다.
        //기존 전체 스테이킹 토큰 당 리워드 토큰 개수에 새로운 구간에서 구한 걸 더해준다.
        //earn에서 들어온 경우 lastUpdateTime = lastTimeRewardApplicable(); 로직에 의해서 rewardPerTokenStored + 0 / _totalSupply; 가된다.
        return rewardPerTokenStored + (rewardRate * (lastTimeRewardApplicable() - lastUpdateTime) * 1e18) / _totalSupply;
        
    }//전체 구간에서의 스테이킹 토큰 당 리워드 토큰 개수를 구하는 함수이다.

    function earned(address account) public view returns(uint256){
        
        //_balances[account] * rewardPerToken() -> account의 전체 구간의 보상
        // _balances[account] * userRewardPerTokenPaid[account] -> 이미 계산된 바로 전 구간의 스테이킹 당 보상

        //유저가 예치한 금액*(전체 구간의 보상 - 이전 구간까지의 보상) = 현재 구간의 보상, 1e18은 10의 18승이라는 의미
        //rewards[account]는 특정 계정에 대한 이전 구간의 누적 보상을 의미한다. 즉 현재 구간 보상 + 누적 보상
        return (_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account]; 

    }//전체 스테이크 토큰당 리워드 토큰 중 사용자의 리워드 토큰 비중을 구한다.

    modifier updateReward(address account){
        //updateReward가 호출될 때 수정됨. 즉 스테이킹 토큰이 변할 때 마다 모든 계정이 영향 받는다.
        rewardPerTokenStored = rewardPerToken();

        lastUpdateTime = lastTimeRewardApplicable();

        //아래 로직은 특정 계정만 영향 받는다.
        if(account != address(0)){

            rewards[account] = earned(account);

            //유저의 스테이킹 수량이 달라질 때(stake, unstake) userRewardPerTokenPaid가 업데이트 된다.
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }//스테이킹 amount가 바뀌는 모든 시점에 호출됨

}