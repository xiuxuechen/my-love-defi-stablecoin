-include .env

.PHONY: all test clean deploy deploy-sepolia deploy-local deploy-zk deploy-zk-sepolia \
        fund fund-local fund-sepolia withdraw withdraw-local withdraw-sepolia \
        help install snapshot format anvil zk-anvil
		
DEFAULT_ANVIL_PRIVATE_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

install:
	@echo "📦 安装依赖..."
	forge install https://github.com/foundry-rs/forge-std
	forge install https://github.com/OpenZeppelin/openzeppelin-contracts
	forge install https://github.com/smartcontractkit/chainlink-evm
	forge install https://github.com/cyfrin/foundry-devops
	forge install https://github.com/transmissions11/solmate

remove: rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules && git add . && git commit -m "modules"

deploy-mlsc-local:
	@echo "📦 部署本地环境..."	
	forge script script/DeployMLSC.s.sol:DeployMLSC \
	 --rpc-url http://localhost:8545 \
	 --private-key $(DEFAULT_ANVIL_PRIVATE_KEY) \
	 --broadcast \
	 -vvvv;

deploy-mlsc-sepolia:
	@echo "📦 部署sepolia测试环境..."	
	forge script script/DeployMLSC.s.sol:DeployMLSC \
	 --rpc-url $(SEPOLIA_RPC_URL) \
	 --private-key $(SEPOLIA_PRIVATE_KEY) \
	 --broadcast \
	 --verify --etherscan-api-key $(ETHERSCAN_API_KEY) \
	 -vvvv;	 
