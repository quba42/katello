import { testSelectorsSnapshotWithFixtures } from 'react-redux-test-utils';
import {
  selectSubscriptionsState,
  selectSearchQuery,
  selectDeleteModalOpened,
  selectDeleteButtonDisabled,
  selectSubscriptionsTask,
  selectHasUpstreamConnection,
  selectSimpleContentAccessEligible,
} from '../SubscriptionsSelectors';

const state = {
  katello: {
    subscriptions: {
      searchQuery: 'some-query',
      deleteModalOpened: false,
      taskModalOpened: false,
      deleteButtonDisabled: true,
      hasUpstreamConnection: false,
      simpleContentAccessEligible: false,
      task: {},
    },
  },
};

const fixtures = {
  'should select the subscriptions state': () => selectSubscriptionsState(state),
  'should select search-query': () => selectSearchQuery(state),
  'should select delete-modal-opened': () => selectDeleteModalOpened(state),
  'should select delete-button-disabled': () => selectDeleteButtonDisabled(state),
  'should select subscriptions task': () => selectSubscriptionsTask(state),
  'should select whether we have an upstream connection': () => selectHasUpstreamConnection(state),
  'should select whether we are simple content access eligible': () => selectSimpleContentAccessEligible(state),
};

describe('Subscriptions selectors', () => testSelectorsSnapshotWithFixtures(fixtures));
