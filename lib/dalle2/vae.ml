open Base
open Torch

module LayerNormChan = struct
  type t = {
    eps : float;
    gamma : Tensor.t;
  }

  let create dim eps =
    {
      eps;
      gamma = Tensor.ones [ 1; dim; 1; 1 ] ~dtype:D.Float;
    }

  let forward norm x =
    let var = Tensor.var x ~dim:1 ~unbiased:false ~keepdim:true in
    let mean = Tensor.mean x ~dim:1 ~keepdim:true in
    let normalized =
      (x - mean) / (var +. norm.eps |> Tensor.sqrt) * norm.gamma
    in
    normalized
end

module Discriminator = struct
  type t = {
    layers : nn Sequential.t list;
    to_logits : nn Sequential.t;
  }

  let create dims ~channels ~groups ~init_kernel_size =
    let dim_pairs = List.zip_exn dims (List.tl_exn dims) in
    let layers =
      List.fold dims ~init:[]
        ~f:(fun acc dim_out ->
          let layer =
            nn
              [
                nn (Conv2d.conv2d ~ksize:4 ~stride:2 ~padding:1 ~input_dim:channels ~output_dim:dim_out ());
                leaky_relu ();
              ]
          in
          layer :: acc)
      |> List.rev
    in
    let dim = List.last_exn dims in
    let to_logits =
      nn
        [
          nn (Conv2d.conv2d ~ksize:1 ~input_dim:dim ~output_dim:dim ());
          leaky_relu ();
          nn (Conv2d.conv2d ~ksize:4 ~input_dim:dim ~output_dim:1 ());
        ]
    in
    { layers; to_logits }
end

module ContinuousPositionBias = struct
  type t = {
    net : nn Sequential.t list;
    rel_pos : Tensor.t option;
  }

  let create ~dim ~heads ~layers =
    let net =
      List.fold
        (List.range 0 layers)
        ~init:[ nn (Linear.linear ~input_dim:2 ~output_dim:dim ()); leaky_relu () ]
        ~f:(fun acc _ ->
          acc
          @ [ nn (Linear.linear ~input_dim:dim ~output_dim:dim ()); leaky_relu () ])
      @ [ nn (Linear.linear ~input_dim:dim ~output_dim:heads ()); ]
    in
    { net }
end

module ResBlock = struct
  type t = {
    net : nn Sequential.t list;
  }

  let create ~chan ~groups =
    let net =
      [
        Conv2d.conv2d ~ksize:3 ~padding:1 ~input_dim:chan ~output_dim:chan ();
        nn (GroupNorm.group_norm ~groups ~channels:chan ());
        leaky_relu ();
        Conv2d.conv2d ~ksize:3 ~padding:1 ~input_dim:chan ~output_dim:chan ();
        nn (GroupNorm.group_norm ~groups ~channels:chan ());
        leaky_relu ();
        Conv2d.conv2d ~ksize:1 ~input_dim:chan ~output_dim:chan ();
      ]
    in
    { net }

  let forward resblock x =
    let residual = x in
    let x = forward_layers resblock.net x in
    Tensor.add x residual
  end