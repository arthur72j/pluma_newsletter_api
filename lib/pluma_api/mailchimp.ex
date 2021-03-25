defmodule PlumaApi.Mailchimp do
  alias PlumaApi.Mailchimp.Repo, as: MR
  alias PlumaApi.Subscriber
  alias PlumaApiWeb.Inputs.Subscriber.NewSubscriber
  require OK

  @default_success_code 200

  defp process_response(response, success_code \\ @default_success_code) do
    case response do
      %{ status_code: ^success_code, body: body } -> {:ok, decode_response_body(body)}
      %{ status_code: _error_code, body: body } -> {:error, decode_response_body(body)}
    end
  end

  defp decode_response_body(""), do: %{}
  defp decode_response_body(body), do: Jason.decode!(body)

  @doc """
  Checks to see if the Mailchimp API is responding/listening.

  Returns an `{:ok, %{"health_status" => health_status :: String.t}}` tuple if active.
  Otherwise returns an `:error` tuple.
  """
  def check_health() do
    MR.check_health()
    |> process_response
  end

  def get_subscriber(email, list_id) do
    MR.get_subscriber(email, list_id)
    |> process_response
  end

  @doc """
  Adds a subscriber to a given Mailchimp audience.
  `subscriber` -> a map of subscriber values or a `Subscriber` or a `NewSubscriber` struct.
  `list_id` -> the mailchimp list to which the subscriber will be added.
  `status` -> one-of "pending" or "subscribed". "pending" subscribers are not formally in the 
              Mailchimp list: instead, a confirmation request is sent to the subscriber. If
              "subscribed", the API invokes a Webhook which is handled by our server, and the 
              subscriber is formally added to the list.
  `test?` -> whether to include a "Test" tag in the data passed to Mailchimp. Useful in case 
              we need to manually delete test-created subscribers.

  Returns `{:ok, body}` or `{:error, error_body}`
  """
  def add_to_audience(subscriber = %NewSubscriber{}, list_id) do
    Jason.encode!(subscriber)
    |> MR.add_to_audience(list_id)
    |> process_response
  end
  def add_to_audience(sub, list_id), do: add_to_audience(sub, list_id, "pending", false)
  def add_to_audience(sub, list_id, status) when status in ["pending", "subscribed"], do: add_to_audience(sub, list_id, status, false)
  def add_to_audience(subscriber = %NewSubscriber{}, list_id, status, test?) when status in ["pending", "subscribed"] do
    %{ subscriber | status: status, tags: subscriber.tags ++ (if test?, do: ["Test"], else: []) }
    |> add_to_audience(list_id)
  end
  def add_to_audience(subscriber = %Subscriber{}, list_id, status, test?) do
    add_to_audience(Map.from_struct(subscriber), list_id, status, test?)
  end
  def add_to_audience(params, list_id, status, test?) when is_map(params) or is_struct(params) do
    case NewSubscriber.validate_input(params) do
      {:ok, new_sub} -> add_to_audience(new_sub, list_id, status, test?)
      error -> error
    end
  end
  def add_to_audience(email, list_id, status, test?), do: add_to_audience(%{"email" => email}, list_id, status, test?)

  @doc """
  Adds tags to a given subscriber in a Mailchimp audience. Tags are passed as a list of
  `maps`, eg: `[%{ name: "VIP", status: "active" }]`
  """
  def tag_subscriber(email, list_id, tags) when is_list(tags) do
    MR.tag_subscriber(email, list_id, tags)
    |> process_response(204)
  end

  @doc """
  Creates a new Merge Field for subscribers in a list. By default the new merge field
  is not public and is not a required field.

  Of interest is the `merge_id` value returned by Mailchimp on success, which is 
  required if we want to update the merge field itself in the future.
  """
  def create_merge_field(list_id, field_name, field_type) do
    MR.create_merge_field(list_id, field_name, field_type)
    |> process_response
  end

  @doc """
  Updates a set of Merge Fields (custom mailchimp subscriber fields) for a given subscriber.

  `merge_fields` is a `map` of Merge Fields and the new value desired. Eg. `%{"PRID" => "cokoo"}`
  """
  def update_merge_field(email, list_id, merge_fields) when is_map(merge_fields) do
    MR.update_merge_field(email, list_id, merge_fields)
    |> process_response
  end

  @doc """
  Check whether a given email exists in the provided list.

  Returns `true` or `false`.
  """
  def check_exists(email, list_id) do
    case MR.check_exists(email, list_id) do
      %{status_code: 200} -> true
      _other -> false
    end
  end

  @doc """
  Remove a subscriber from a given Mailchimp audience list. Subscriber will remain archived.

  Returns `{:ok, %{}}` if successful, `{:error, error}` otherwise.
  """ 
  def archive_subscriber(email, list_id) do
    MR.archive_subscriber(email, list_id)
    |> process_response(204)
  end

  @doc """
  Permanently delete a subscriber from a given Mailchimp audience list.

  Deleted subscribers CANNOT be reimported, unlike archived subs.

  Returns `{:ok, %{}}` if successful, `{:error, error}` otherwise.
  """ 
  def delete_subscriber(email, list_id) do
    MR.delete_subscriber(email, list_id)
    |> process_response(204)
  end

  @doc """
  Synchronizes remote and local RID values, given a local subscriber (`Subscriber`) and 
  an external subscriber (a `map` of subscriber parameters). Used with the webhook interface.

  Can handle missing RID's on both ends, with a bias towards a local RID. Will correct incongruent
  RID's as well.

  Returns `{:ok, subscriber}` where subscriber is the synced subscriber. 
  Also returns `{:error, {:remote_update_error, {sub, response}}}` and `{:error, {:local_update_error, {sub, chgst}}}` in case
  there's a problem communicating with the remote API or local DB.
  """
  def sync_remote_and_local_RIDs(local_sub = %Subscriber{rid: ""}, external_sub, list_id), do: sync_remote_and_local_RIDs(%{ local_sub | rid: nil }, external_sub, list_id)
  def sync_remote_and_local_RIDs(local_sub = %Subscriber{rid: nil}, _external_sub = %{rid: ""}, list_id) do
    OK.for do
      new_rid = Nanoid.generate()
      _remote_update <- update_remote(local_sub, %{ "RID": new_rid }, list_id)
      local_update <- update_local(local_sub, %{ rid: new_rid })
    after
      {:ok, local_update}
    end
  end
  def sync_remote_and_local_RIDs(local_sub = %Subscriber{rid: nil}, _external_sub = %{rid: rid}, _list_id) do
    OK.for do
      local_update <- update_local(local_sub, %{ rid: rid })
    after
      {:ok, local_update}
    end
  end
  def sync_remote_and_local_RIDs(local_sub = %Subscriber{rid: rid}, _external_sub = %{rid: ""}, list_id) do
    OK.for do
      _remote_update <- update_remote(local_sub, %{ "RID": rid }, list_id)
    after
      {:ok, local_sub}
    end
  end
  def sync_remote_and_local_RIDs(local_sub = %Subscriber{rid: local_rid}, %{rid: remote_rid}, list_id) do 
    if not String.equivalent?(local_rid, remote_rid) do
      OK.for do
        _remote_update <- update_remote(local_sub, %{ "RID": local_rid }, list_id)  
      after
        {:ok, local_sub}
      end
    else
      {:ok, local_sub}
    end
  end

  defp update_remote(subscriber = %Subscriber{}, updated_fields, list_id) when is_map(updated_fields) do
    update_merge_field(subscriber.email, list_id, updated_fields)
    |> case do
      {:ok, response} -> {:ok, response}
      {:error, error_response} -> {:error, {:remote_update_error, {subscriber, error_response}}}
    end
  end

  defp update_local(subscriber = %Subscriber{}, updated_fields) do
    Subscriber.insert_changeset(subscriber, updated_fields)
    |> PlumaApi.Repo.update
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, chgst} -> {:error, {:local_update_error, {subscriber, chgst}}}
    end
  end

end
