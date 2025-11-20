// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ManagerLib
 * @notice Library for manager access control
 */
library ManagerLib {
    struct ManagerData {
        mapping(address => bool) isManager;
        address[] list;
        mapping(address => uint256) index;
    }

    error NotManager();
    error AlreadyManager();
    error NotAManager();
    error OwnerCannotBeManager();

    event ManagerAdded(address indexed manager, address indexed addedBy);
    event ManagerRemoved(address indexed manager, address indexed removedBy);

    function add(
        ManagerData storage self,
        address manager,
        address owner
    ) internal {
        if (manager == address(0) || manager == owner)
            revert OwnerCannotBeManager();
        if (self.isManager[manager]) revert AlreadyManager();

        self.isManager[manager] = true;
        self.index[manager] = self.list.length;
        self.list.push(manager);

        emit ManagerAdded(manager, msg.sender);
    }

    function remove(ManagerData storage self, address manager) internal {
        if (!self.isManager[manager]) revert NotAManager();

        self.isManager[manager] = false;

        uint256 idx = self.index[manager];
        uint256 lastIdx = self.list.length - 1;

        if (idx != lastIdx) {
            address lastManager = self.list[lastIdx];
            self.list[idx] = lastManager;
            self.index[lastManager] = idx;
        }

        self.list.pop();
        delete self.index[manager];

        emit ManagerRemoved(manager, msg.sender);
    }

    function check(
        ManagerData storage self,
        address account,
        address owner
    ) internal view {
        if (!self.isManager[account] && account != owner) revert NotManager();
    }
}
