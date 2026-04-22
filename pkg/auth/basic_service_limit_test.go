package auth

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"github.com/treeverse/lakefs/pkg/auth/crypt"
	"github.com/treeverse/lakefs/pkg/auth/model"
	authparams "github.com/treeverse/lakefs/pkg/auth/params"
	"github.com/treeverse/lakefs/pkg/kv/kvtest"
	"github.com/treeverse/lakefs/pkg/logging"
)

func TestBasicAuthService_MaxCredentialsPerUser(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	store := kvtest.GetStore(ctx, t)
	s := NewBasicAuthService(store, crypt.NewSecretStore([]byte("sekret")), authparams.ServiceCache{
		Enabled: false,
	}, logging.ContextUnavailable())

	username := "admin"
	_, err := s.CreateUser(ctx, &model.User{Username: username})
	require.NoError(t, err)

	for range MaxCredentialsPerUser {
		_, err := s.CreateCredentials(ctx, username)
		require.NoError(t, err)
	}
	_, err = s.CreateCredentials(ctx, username)
	require.ErrorIs(t, err, ErrInvalidRequest)
}

func TestBasicAuthService_DeleteLastCredentialRejected(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	store := kvtest.GetStore(ctx, t)
	s := NewBasicAuthService(store, crypt.NewSecretStore([]byte("sekret")), authparams.ServiceCache{
		Enabled: false,
	}, logging.ContextUnavailable())

	username := "solo"
	_, err := s.CreateUser(ctx, &model.User{Username: username})
	require.NoError(t, err)
	creds, err := s.CreateCredentials(ctx, username)
	require.NoError(t, err)

	err = s.DeleteCredentials(ctx, username, creds.AccessKeyID)
	require.ErrorIs(t, err, ErrInvalidRequest)
}

func TestBasicAuthService_DeleteCredentialsEvictsLRUCache(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	store := kvtest.GetStore(ctx, t)
	s := NewBasicAuthService(store, crypt.NewSecretStore([]byte("sekret")), authparams.ServiceCache{
		Enabled: true,
		Size:    128,
		TTL:     time.Minute,
		Jitter:  time.Second,
	}, logging.ContextUnavailable())

	username := "cached"
	_, err := s.CreateUser(ctx, &model.User{Username: username})
	require.NoError(t, err)
	first, err := s.CreateCredentials(ctx, username)
	require.NoError(t, err)
	second, err := s.AddCredentials(ctx, username, "AKIAEXPLICITKEY0001", "explicit-secret-one")
	require.NoError(t, err)

	got, err := s.GetCredentials(ctx, first.AccessKeyID)
	require.NoError(t, err)
	require.Equal(t, first.SecretAccessKey, got.SecretAccessKey)

	require.NoError(t, s.DeleteCredentials(ctx, username, first.AccessKeyID))

	_, err = s.GetCredentials(ctx, first.AccessKeyID)
	require.ErrorIs(t, err, ErrNotFound)

	still, err := s.GetCredentials(ctx, second.AccessKeyID)
	require.NoError(t, err)
	require.Equal(t, second.SecretAccessKey, still.SecretAccessKey)
}

func TestBasicAuthService_ListUserCredentialsPagination(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	store := kvtest.GetStore(ctx, t)
	s := NewBasicAuthService(store, crypt.NewSecretStore([]byte("sekret")), authparams.ServiceCache{
		Enabled: false,
	}, logging.ContextUnavailable())

	username := "page"
	_, err := s.CreateUser(ctx, &model.User{Username: username})
	require.NoError(t, err)
	_, err = s.AddCredentials(ctx, username, "AKIAZEBRA", "z-secret")
	require.NoError(t, err)
	_, err = s.AddCredentials(ctx, username, "AKIAMANGO", "m-secret")
	require.NoError(t, err)

	page1, p1, err := s.ListUserCredentials(ctx, username, &model.PaginationParams{Amount: 1})
	require.NoError(t, err)
	require.Len(t, page1, 1)
	require.Equal(t, "AKIAMANGO", page1[0].AccessKeyID)
	require.NotEmpty(t, p1.NextPageToken)

	page2, p2, err := s.ListUserCredentials(ctx, username, &model.PaginationParams{
		Amount: 1,
		After:  p1.NextPageToken,
	})
	require.NoError(t, err)
	require.Len(t, page2, 1)
	require.Equal(t, "AKIAZEBRA", page2[0].AccessKeyID)
	require.Empty(t, p2.NextPageToken)
}
